#!/usr/bin/env bash
# So sánh thời gian khởi động và kích thước binary giữa các mức tối ưu.
#
#   ./startup.sh                 # so default vs fast, 5 lần mỗi bên
#   RUNS=3 ./startup.sh fast     # chỉ 1 tune
#
# total_ms  = từ lúc shell exec đến khi app xong applicationDidFinishLaunching.
#             Gồm cả dyld load AppKit/WebKit — phần chiếm đa số.
# main_ms   = chỉ phần code của app, từ đầu top-level đến ready.
#             Đây mới là phần mà flag compiler có thể ảnh hưởng.
set -euo pipefail
set +m   # tắt job control, khỏi in "Terminated: 15" mỗi lần pkill
cd "$(dirname "$0")"

RUNS=${RUNS:-5}
BIN="$PWD/FB Mess.app/Contents/MacOS/Messenger"
APP_PATTERN='FB Mess\.app/Contents/MacOS/Messenger'
TUNES=("$@"); [[ ${#TUNES[@]} -eq 0 ]] && TUNES=(default fast)

now() { python3 -c 'import time; print(time.time())'; }

printf "%-9s %10s %12s %12s %12s %12s\n" TUNE "BINARY KB" "total avg" "total min" "main avg" "main min"

for tune in "${TUNES[@]}"; do
    RELEASE_TUNE="$tune" ./build.sh >/dev/null 2>&1
    size_kb=$(( $(stat -f %z "$BIN") / 1024 ))

    totals=(); mains=()
    for i in $(seq 1 "$RUNS"); do
        pkill -f "$APP_PATTERN" 2>/dev/null || true
        sleep 2
        log="startup-$tune.log"
        : > "$log"

        t0=$(now)
        FBMESS_DIAG=1 "$BIN" >"$log" 2>&1 &

        # đợi dòng ready, tối đa 20s
        ready=""
        for _ in $(seq 1 200); do
            ready=$(grep -o 'ready main_ms=[0-9.]* epoch=[0-9.]*' "$log" 2>/dev/null | head -1 || true)
            [[ -n "$ready" ]] && break
            sleep 0.1
        done
        [[ -z "$ready" ]] && { echo "  run $i: không thấy dòng ready, bỏ"; continue; }

        main_ms=$(sed -E 's/.*main_ms=([0-9.]+).*/\1/' <<<"$ready")
        epoch=$(sed -E 's/.*epoch=([0-9.]+).*/\1/' <<<"$ready")
        total_ms=$(awk -v a="$t0" -v b="$epoch" 'BEGIN{printf "%.1f", (b-a)*1000}')

        totals+=("$total_ms"); mains+=("$main_ms")
    done

    pkill -f "$APP_PATTERN" 2>/dev/null || true

    stats() { printf '%s\n' "$@" | awk '{s+=$1; if(m==""||$1<m)m=$1; n++} END{printf "%.1f %.1f", s/n, m}'; }
    read -r t_avg t_min <<<"$(stats "${totals[@]}")"
    read -r m_avg m_min <<<"$(stats "${mains[@]}")"

    printf "%-9s %10d %12s %12s %12s %12s\n" \
        "$tune" "$size_kb" "$t_avg" "$t_min" "$m_avg" "$m_min"
done

echo
echo "Đơn vị ms. n=$RUNS mỗi tune."
