#!/usr/bin/env bash
# Đo memory + CPU của app kể cả helper process.
#
#   ./measure.sh 4Message                    # chụp 1 thời điểm
#   ./measure.sh 4Message --watch            # theo dõi liên tục, ghi CSV
#   INTERVAL=300 ./measure.sh 4Message --watch
#
# Nguồn số: `/usr/bin/footprint --json` → byte CHÍNH XÁC, đọc bằng `plutil` (luôn có
# trên macOS, không cần python). Trước đây parse text của `vmmap`, nhưng trên 1 GB nó in
# "1.4G" nên độ phân giải chỉ còn 100 MB — hai mẫu liên tiếp cùng đọc "1024.0 MB" đã che
# mất một thay đổi thật. `footprint` cũng nhanh hơn (~0.03s so với ~0.5s mỗi process).
#
# Ngoài footprint còn báo:
#   RECLAIM — trang OS lấy lại được NGAY (clean/purgeable). KHÔNG tính phần cache mà
#             WebKit tự purge khi nhận notification memory pressure — mà chính phần đó
#             tạo ra mức giảm 42% trong pressure-test. Nên RECLAIM thấp KHÔNG kết luận
#             được là leak. Muốn phân biệt cache với leak: xem đường có plateau không,
#             (script pressure-test.sh đã xoá cùng bản Swift; xem docs/perf-process.md).
#   PEAK    — mức cao nhất từ lúc process sinh ra (chỉ ở snapshot mode).
#
# Không dùng RSS: bỏ qua trang đã bị nén nên báo thiếu (348 MB RSS cho process mà
# Activity Monitor báo 1.35 GB), lại gộp trang framework dùng chung với Safari nên ở
# chiều khác báo thừa.
#
# Attribution: WebContent lấy từ unified log (macOS gán log của XPC service về app chịu
# trách nhiệm). GPU/Networking không được log nên nhận theo "sinh trong vòng 20s quanh
# lúc app launch" — hẹp hơn "trẻ hơn app", cái đó gom cả WebContent của Safari/Slack.
set -uo pipefail

APP="${1:-4Message}"   # mặc định app hiện tại; truyền tên khác nếu cần
MODE="${2:-snapshot}"
INTERVAL="${INTERVAL:-60}"
CSV="${CSV:-memory-track.csv}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

have_footprint=0
[[ -x /usr/bin/footprint ]] && have_footprint=1

age_secs() {
    local e
    e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')
    [[ -z "$e" ]] && return 1
    awk -F'[-:]' 'NF==2{print $1*60+$2} NF==3{print $1*3600+$2*60+$3} NF==4{print $1*86400+$2*3600+$3*60+$4}' <<<"$e"
}

bytes_to_mb() { awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1048576}'; }

# Đặt F_CUR / F_RECLAIM / F_PEAK (MB) cho 1 pid. Rỗng nếu không đọc được.
read_footprint() {
    local pid=$1 j="$TMP/f.json" raw
    F_CUR=""; F_RECLAIM=""; F_PEAK=""

    if (( have_footprint )); then
        rm -f "$j"
        if /usr/bin/footprint --json "$j" "$pid" >/dev/null 2>&1 && [[ -s "$j" ]]; then
            raw=$(plutil -extract processes.0.footprint raw -o - "$j" 2>/dev/null || true)
            [[ -n "$raw" ]] && F_CUR=$(bytes_to_mb "$raw")
            # peak nằm trong `auxiliary`, KHÔNG ở process level.
            raw=$(plutil -extract processes.0.auxiliary.phys_footprint_peak raw -o - "$j" 2>/dev/null || true)
            [[ -n "$raw" ]] && F_PEAK=$(bytes_to_mb "$raw")
        fi
        # `reclaimable` chỉ có theo từng category trong JSON, không có tổng. Lấy từ dòng
        # TOTAL của output text (chính xác tới MB — đủ, ta chỉ cần độ lớn).
        F_RECLAIM=$(/usr/bin/footprint "$pid" 2>/dev/null | awk '
            $NF=="TOTAL" {
                v=$5; u=$6; n=v+0
                if (u ~ /^G/) n*=1024; else if (u ~ /^K/) n/=1024; else if (u ~ /^B/) n/=1048576
                printf "%.1f", n; exit
            }')
    fi

    # Fallback: vmmap. Kém chính xác trên 1 GB (bước 100 MB) nhưng còn hơn không có gì.
    if [[ -z "$F_CUR" ]]; then
        F_CUR=$(vmmap --summary "$pid" 2>/dev/null | awk -F: '/Physical footprint:/{
            gsub(/ /,"",$2); v=$2; u=substr(v,length(v)); n=v+0
            if (u=="G") n*=1024; else if (u=="K") n/=1024
            printf "%.1f", n; exit }')
    fi
}

ROOT_PID=""; HELPERS=""; ATTRIBUTION=""

# Tốn vài giây vì gọi `log show`, nên watch mode chỉ gọi lại khi app đổi PID.
resolve_pids() {
    ROOT_PID=$(pgrep -f "${APP}.app/Contents/MacOS/" 2>/dev/null | head -1 || true)
    [[ -z "$ROOT_PID" ]] && return 1

    local exec_name uptime_min app_age a d
    exec_name=$(basename "$(ps -o comm= -p "$ROOT_PID")")

    # Cửa sổ log phải phủ tới lúc launch: helper chỉ log khi khởi động.
    uptime_min=$(( ($(age_secs "$ROOT_PID" || echo 60) / 60) + 1 ))
    (( uptime_min > 180 )) && uptime_min=180
    (( uptime_min < 5 )) && uptime_min=5

    HELPERS=$(/usr/bin/log show --predicate "process == \"$exec_name\"" --last "${uptime_min}m" 2>/dev/null \
        | grep -oE 'WebContent\[[0-9]+\]' | grep -oE '[0-9]+' | sort -un || true)
    ATTRIBUTION="unified log (WebContent) + cùng thời điểm launch (GPU/Networking)"

    app_age=$(age_secs "$ROOT_PID" || echo 0)
    for p in $(pgrep -f 'com.apple.WebKit.(GPU|Networking)' 2>/dev/null || true); do
        a=$(age_secs "$p") || continue
        d=$(( app_age > a ? app_age - a : a - app_age ))
        (( d <= 20 )) && HELPERS="$HELPERS $p"
    done

    if [[ -z "${HELPERS// /}" ]]; then
        ATTRIBUTION="fallback: child process (KÉM CHÍNH XÁC)"
        HELPERS=$(pgrep -P "$ROOT_PID" 2>/dev/null || true)
    fi
    return 0
}

add() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{printf "%.1f", a+b}'; }

sample() {
    S_APP=0; S_GPU=0; S_NET=0; S_WEB=0; S_NWEB=0; S_TOTAL=0; S_CPU=0; S_RECLAIM=0
    S_ROWS=()
    local pid cpu name
    for pid in $(tr ' ' '\n' <<<"$ROOT_PID $HELPERS" | grep -E '^[0-9]+$' | sort -un); do
        read_footprint "$pid"
        [[ -z "$F_CUR" ]] && continue
        cpu=$(ps -o pcpu= -p "$pid" 2>/dev/null | tr -d ' '); [[ -z "$cpu" ]] && cpu=0
        name=$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)" 2>/dev/null || echo '?')
        case "$name" in
            *WebKit.GPU)        S_GPU=$(add "$S_GPU" "$F_CUR") ;;
            *WebKit.Networking) S_NET=$(add "$S_NET" "$F_CUR") ;;
            *WebKit.WebContent) S_WEB=$(add "$S_WEB" "$F_CUR"); S_NWEB=$((S_NWEB+1)) ;;
            *)                  S_APP=$(add "$S_APP" "$F_CUR") ;;
        esac
        S_TOTAL=$(add "$S_TOTAL" "$F_CUR")
        S_RECLAIM=$(add "$S_RECLAIM" "${F_RECLAIM:-0}")
        S_CPU=$(add "$S_CPU" "$cpu")
        S_ROWS+=("$pid|$name|$F_CUR|${F_RECLAIM:-–}|${F_PEAK:-–}|$cpu")
    done
}

resolve_pids || { echo "Không thấy process nào của '${APP}'. App đang chạy chưa?" >&2; exit 1; }

if [[ "$MODE" != "--watch" ]]; then
    sample
    printf "%-8s %11s %11s %11s %7s  %s\n" PID "NOW MB" "RECLAIM" "PEAK MB" "%CPU" PROCESS
    for r in "${S_ROWS[@]}"; do
        IFS='|' read -r pid name cur rec peak cpu <<<"$r"
        printf "%-8s %11s %11s %11s %7s  %s\n" "$pid" "$cur" "$rec" "$peak" "$cpu" "$name"
    done
    echo "─────────────────────────────────────────────────────────────────────"
    printf "%-8s %11s %11s %11s %7s\n" TỔNG "$S_TOTAL" "$S_RECLAIM" "" "$S_CPU"
    echo
    echo "attribution: $ATTRIBUTION"
    echo "RECLAIM = trang OS lấy lại được NGAY. KHÔNG tính cache WebKit tự purge khi có"
    echo "          memory pressure, nên RECLAIM thấp KHÔNG kết luận được là leak."
    echo "PEAK    = mức cao nhất từ lúc process sinh ra."
    echo "Ảnh chụp 1 thời điểm — dùng --watch để thấy memory phình theo giờ."
    exit 0
fi

# ── watch mode ──
[[ -f "$CSV" ]] || echo "time,uptime_s,app_mb,gpu_mb,net_mb,webcontent_mb,n_webcontent,total_mb,reclaim_mb,cpu_pct" > "$CSV"

echo "Theo dõi mỗi ${INTERVAL}s, ghi vào $CSV. Ctrl-C để dừng."
echo "attribution: $ATTRIBUTION"
(( have_footprint )) || echo "⚠ không có /usr/bin/footprint — dùng vmmap, độ phân giải 100 MB khi >1 GB"
echo
printf "%-9s %8s %7s %7s %10s %4s %9s %9s %8s\n" TIME APP GPU NET WEBCONTENT nWC TỔNG RECLAIM "Δ TỔNG"

BASE=""
while true; do
    if ! kill -0 "$ROOT_PID" 2>/dev/null || [[ "$(pgrep -f "${APP}.app/Contents/MacOS/" | head -1)" != "$ROOT_PID" ]]; then
        if resolve_pids; then
            echo "  → app đổi PID (relaunch), tra lại: $ROOT_PID"
            BASE=""   # process mới không so được với process cũ
        else
            echo "  → app không còn chạy, chờ..."; sleep "$INTERVAL"; continue
        fi
    fi

    sample
    [[ -z "$BASE" ]] && BASE="$S_TOTAL"
    delta=$(awk -v a="$S_TOTAL" -v b="$BASE" 'BEGIN{printf "%+.1f", a-b}')

    printf "%-9s %8s %7s %7s %10s %4s %9s %9s %8s\n" \
        "$(date +%H:%M:%S)" "$S_APP" "$S_GPU" "$S_NET" "$S_WEB" "$S_NWEB" "$S_TOTAL" "$S_RECLAIM" "$delta"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$(age_secs "$ROOT_PID" || echo 0),$S_APP,$S_GPU,$S_NET,$S_WEB,$S_NWEB,$S_TOTAL,$S_RECLAIM,$S_CPU" >> "$CSV"

    sleep "$INTERVAL"
done
