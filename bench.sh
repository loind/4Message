#!/usr/bin/env bash
# Quy trình đo hiệu năng có thể lặp lại, so sánh các mode của FB Mess.
#
#   ./bench.sh                          # đo cả 4 mode
#   ./bench.sh baseline throttle        # chỉ 2 mode
#   LOAD=30 SOAK=60 ./bench.sh block    # rút ngắn để smoke test
#
# Giao thức mỗi mode:
#   t=0        launch (cửa sổ hiện, trang load)
#   t=LOAD-15  đo trạng thái VISIBLE (footprint + CPU)
#   t=LOAD     app tự ẩn cửa sổ (FBMESS_BENCH_HIDE_AFTER)
#   t=LOAD+SOAK/2  đo delta network → kết nối realtime còn sống không
#   t=LOAD+SOAK    đo trạng thái HIDDEN (footprint + CPU)
#
# Attribution chính xác: chụp danh sách WebKit XPC process TRƯỚC khi launch,
# process nào mới xuất hiện sau đó là của app. Không dùng heuristic.
set -euo pipefail
cd "$(dirname "$0")"

# Tuyệt đối: launch bằng đường dẫn tương đối thì argv không có "/" đầu và
# pkill -f với pattern có "/" sẽ không khớp → instance cũ sống sót, số liệu nhiễu.
BIN="$PWD/FB Mess.app/Contents/MacOS/Messenger"
APP_PATTERN='FB Mess\.app/Contents/MacOS/Messenger'
LOAD=${LOAD:-120}
SOAK=${SOAK:-180}
# NOHIDE=1 → control run: không bao giờ ẩn cửa sổ. Dùng để tách phần memory
# tăng theo thời gian khỏi phần giảm được nhờ ẩn.
NOHIDE=${NOHIDE:-0}
CPU_WINDOW=${CPU_WINDOW:-10}
OUT=${OUT:-bench-results.md}

MODES=("$@")
[[ ${#MODES[@]} -eq 0 ]] && MODES=(baseline throttle suspend block)

[[ -x "$BIN" ]] || { echo "Chưa có $BIN — chạy ./build.sh trước."; exit 1; }

webkit_pids() { pgrep -f 'com.apple.WebKit.(WebContent|Networking|GPU)' 2>/dev/null | sort -n || true; }

# "13 MiB" / "6377 KiB" / "512 B" → MB
to_mb() {
    awk -v v="$1" -v u="$2" 'BEGIN{
        n = v + 0
        if (u ~ /^G/) n *= 1024
        else if (u ~ /^K/) n /= 1024
        else if (u ~ /^B/) n /= 1048576
        printf "%.2f", n
    }'
}

footprint_mb() {
    local total=0 p f
    for p in "$@"; do
        f=$(vmmap --summary "$p" 2>/dev/null | awk -F: '/Physical footprint:/{gsub(/[ ]/,"",$2); print $2; exit}')
        [[ -z "$f" ]] && continue
        total=$(awk -v t="$total" -v v="$f" 'BEGIN{
            u = substr(v, length(v)); n = v + 0
            if (u == "G") n *= 1024; else if (u == "K") n /= 1024
            printf "%.1f", t + n
        }')
    done
    echo "$total"
}

# CPU trung bình trên CPU_WINDOW giây: top -l 2 lấy mẫu thứ 2 (là delta).
cpu_pct() {
    local args=() p
    for p in "$@"; do args+=(-pid "$p"); done
    top -l 2 -s "$CPU_WINDOW" -stats pid,cpu "${args[@]}" 2>/dev/null \
        | awk '/^PID/{n++} n==2 && $1 ~ /^[0-9]+$/ {s += $2} END{printf "%.1f", s+0}'
}

# Byte in+out TÍCH LŨY từ lúc process sinh ra.
# Trước đây dùng delta 5 giây làm proxy "kết nối còn sống" — sai, vì keepalive của
# Messenger cách nhau hàng chục giây nên cửa sổ 5s thường bắt được 0 dù kết nối vẫn tốt.
# Chốt 2 mốc rồi trừ, lấy delta trên cả SOAK mới đọc được.
net_cumulative_kb() {
    local snap total=0 p line
    snap=$(nettop -P -x -l 1 -J bytes_in,bytes_out 2>/dev/null || true)
    for p in "$@"; do
        # dòng cuối khớp pid = mẫu delta
        line=$(grep "\.${p}\b" <<<"$snap" | tail -1 || true)
        [[ -z "$line" ]] && continue
        total=$(awk -v t="$total" \
                    -v a="$(awk '{print $2}' <<<"$line")" -v au="$(awk '{print $3}' <<<"$line")" \
                    -v b="$(awk '{print $4}' <<<"$line")" -v bu="$(awk '{print $5}' <<<"$line")" \
            'function mb(v,u){n=v+0; if(u~/^G/)n*=1048576; else if(u~/^M/)n*=1024; else if(u~/^B/)n/=1024; return n}
             BEGIN{printf "%.1f", t + mb(a,au) + mb(b,bu)}')
    done
    echo "$total"
}

# Dừng mọi instance và VERIFY. Không verify thì instance sót lại sẽ cạnh tranh CPU
# và làm sai toàn bộ phép đo — thà dừng hẳn còn hơn ra số liệu sai.
stop_app() {
    pkill -f "$APP_PATTERN" 2>/dev/null || true
    local i
    for i in $(seq 1 10); do
        pgrep -f "$APP_PATTERN" >/dev/null 2>&1 || { sleep 1; return 0; }
        sleep 1
    done
    pkill -9 -f "$APP_PATTERN" 2>/dev/null || true
    sleep 2
    if pgrep -f "$APP_PATTERN" >/dev/null 2>&1; then
        echo "✗ vẫn còn instance sau khi kill — dừng để tránh số liệu nhiễu" >&2
        exit 1
    fi
}

# Đúng 1 instance mới đo được. Nhiều hơn = nhiễu, ít hơn = app chết.
assert_single_instance() {
    local n
    # macOS pgrep KHÔNG có -c. Phải đếm qua wc, và chặn pipefail khi pgrep không khớp.
    n=$({ pgrep -f "$APP_PATTERN" 2>/dev/null || true; } | wc -l | tr -d ' ')
    [[ "$n" == 1 ]] || { echo "✗ có $n instance đang chạy (cần đúng 1) — dừng" >&2; exit 1; }
}

if [[ ! -f "$OUT" ]]; then
    {
        echo "# Bench FB Mess"
        echo
        echo "T1 = đo lúc cửa sổ còn hiện (~LOAD-15s). T2 = đo sau khi đã ẩn (~LOAD+SOAK)."
        echo "Control run không ẩn cửa sổ, nên T2 của nó là mức tăng theo thời gian thuần."
        echo "So sánh có ý nghĩa là **giữa các mode tại cùng mốc T**, không phải T1→T2 trong cùng mode."
        echo
        echo "| Mode | Footprint T1 (MB) | CPU T1 (%) | Footprint T2 (MB) | CPU T2 (%) | Net khi ẩn (KB/soak) | Process |"
        echo "| --- | --- | --- | --- | --- | --- | --- |"
    } > "$OUT"
fi

echo "LOAD=${LOAD}s SOAK=${SOAK}s CPU_WINDOW=${CPU_WINDOW}s → ~$(( (LOAD + SOAK + 40) * ${#MODES[@]} / 60 )) phút cho ${#MODES[@]} mode"
echo

for mode in "${MODES[@]}"; do
    echo "══════ mode=$mode ══════"
    stop_app

    before=$(webkit_pids)

    # LABEL để phân biệt các run cùng mode nhưng khác biến khác (ví dụ khác FBMESS_URL).
    if [[ "$NOHIDE" == 1 ]]; then
        hide_at=0; label="${LABEL:-$mode} (control, không ẩn)"
    else
        hide_at=$LOAD; label="${LABEL:-$mode}"
    fi

    FBMESS_MODE="$mode" FBMESS_BENCH_HIDE_AFTER="$hide_at" "$BIN" >"bench-$mode.log" 2>&1 &
    app_pid=$!
    sleep 3
    kill -0 "$app_pid" 2>/dev/null || { echo "  ✗ app chết ngay khi launch, bỏ mode này"; continue; }
    assert_single_instance

    ours() {
        local now new
        now=$(webkit_pids)
        new=$(comm -13 <(echo "$before") <(echo "$now") || true)
        echo "$app_pid" $new
    }

    # ── VISIBLE ──
    sleep $(( LOAD - 15 - CPU_WINDOW > 0 ? LOAD - 15 - CPU_WINDOW : 5 ))
    read -r -a pv <<<"$(ours)"
    cpu_vis=$(cpu_pct "${pv[@]}")
    fp_vis=$(footprint_mb "${pv[@]}")
    echo "  visible: ${fp_vis} MB, ${cpu_vis}% CPU, ${#pv[@]} process"

    # ── chờ app tự ẩn, chốt mốc network rồi soak ──
    sleep 20
    read -r -a pn <<<"$(ours)"
    net0=$(net_cumulative_kb "${pn[@]}")

    sleep "$SOAK"
    read -r -a ph <<<"$(ours)"
    cpu_hid=$(cpu_pct "${ph[@]}")
    fp_hid=$(footprint_mb "${ph[@]}")

    # Phải trừ trên ĐÚNG pid set đã lấy net0. Lấy lại pid set ở mốc sau làm
    # delta vô nghĩa: process chết/respawn thì counter tụt về 0 → ra số âm khổng lồ.
    net="n/a"
    if [[ "$(tr ' ' '\n' <<<"${pn[*]}" | sort -n | tr '\n' ' ')" \
       == "$(tr ' ' '\n' <<<"${ph[*]}" | sort -n | tr '\n' ' ')" ]]; then
        net1=$(net_cumulative_kb "${pn[@]}")
        d=$(awk -v a="$net0" -v b="$net1" 'BEGIN{printf "%.1f", b - a}')
        # Âm nghĩa là counter reset → không tin được.
        awk -v v="$d" 'BEGIN{exit !(v >= 0)}' && net="$d" || net="n/a (counter reset)"
    else
        net="n/a (pid đổi giữa 2 mốc)"
    fi
    echo "  hidden : ${fp_hid} MB, ${cpu_hid}% CPU, net ${net} KB trong ${SOAK}s"

    # Nếu cửa sổ bị hiện lại giữa lúc soak thì T2 đo ở trạng thái visible → vô nghĩa.
    if grep -q 'show: reattached' "bench-$mode.log" 2>/dev/null; then
        label="$label ⚠ INVALID: cửa sổ bị hiện lại giữa run"
        echo "  ⚠ phát hiện reattach giữa run — hàng này KHÔNG dùng được"
    fi

    printf "| \`%s\` | %s | %s | %s | %s | %s | %s |\n" \
        "$label" "$fp_vis" "$cpu_vis" "$fp_hid" "$cpu_hid" "$net" "${#ph[@]}" >> "$OUT"

    grep -c . "bench-$mode.log" >/dev/null 2>&1 && sed 's/^/  | /' "bench-$mode.log" | head -6

    stop_app
    echo
done

echo "── kết quả ──"
cat "$OUT"
