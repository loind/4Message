#!/usr/bin/env bash
# Đo memory + CPU của app kể cả helper process.
#
#   ./measure.sh "FB Mess"                    # chụp 1 thời điểm
#   ./measure.sh "FB Mess" --watch            # theo dõi liên tục, ghi CSV
#   INTERVAL=300 ./measure.sh "FB Mess" --watch
#
# Báo `phys_footprint` — CHÍNH LÀ số ở cột Memory của Activity Monitor.
# Không dùng RSS: nó bỏ qua phần memory đã bị nén nên báo thiếu (348 MB RSS cho process
# mà Activity Monitor báo 1.35 GB), và gộp trang framework dùng chung với Safari nên ở
# chiều khác lại báo thừa.
#
# Attribution: WebContent lấy từ unified log (macOS gán log của XPC service về app chịu
# trách nhiệm). GPU/Networking không được log nên nhận theo "sinh trong vòng 20s quanh
# lúc app launch" — hẹp hơn "trẻ hơn app", cái đó gom cả WebContent của Safari/Slack.
set -uo pipefail

APP="${1:?Cần tên app, ví dụ: ./measure.sh \"FB Mess\"}"
MODE="${2:-snapshot}"
INTERVAL="${INTERVAL:-60}"
CSV="${CSV:-memory-track.csv}"

age_secs() {
    local e
    e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')
    [[ -z "$e" ]] && return 1
    awk -F'[-:]' 'NF==2{print $1*60+$2} NF==3{print $1*3600+$2*60+$3} NF==4{print $1*86400+$2*3600+$3*60+$4}' <<<"$e"
}

footprint_mb() {
    vmmap --summary "$1" 2>/dev/null | awk -F: '/Physical footprint:/{
        gsub(/ /,"",$2); v=$2
        u=substr(v,length(v)); n=v+0
        if (u=="G") n*=1024; else if (u=="K") n/=1024
        printf "%.1f", n
    }'
}

ROOT_PID=""
HELPERS=""
ATTRIBUTION=""

# Tra PID. Tốn vài giây vì phải gọi `log show`, nên watch mode chỉ gọi lại khi app
# đổi PID (bị relaunch), không gọi mỗi lần lấy mẫu.
resolve_pids() {
    ROOT_PID=$(pgrep -f "${APP}.app/Contents/MacOS/" 2>/dev/null | head -1 || true)
    [[ -z "$ROOT_PID" ]] && return 1

    local exec_name uptime_min
    exec_name=$(basename "$(ps -o comm= -p "$ROOT_PID")")

    # Cửa sổ log phải phủ tới lúc launch, vì helper chỉ log khi khởi động.
    uptime_min=$(( ($(age_secs "$ROOT_PID" || echo 60) / 60) + 1 ))
    (( uptime_min > 180 )) && uptime_min=180
    (( uptime_min < 5 )) && uptime_min=5

    HELPERS=$(/usr/bin/log show --predicate "process == \"$exec_name\"" --last "${uptime_min}m" 2>/dev/null \
        | grep -oE 'WebContent\[[0-9]+\]' | grep -oE '[0-9]+' | sort -un || true)
    ATTRIBUTION="unified log (WebContent) + cùng thời điểm launch (GPU/Networking)"

    local app_age a d
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

all_pids() { tr ' ' '\n' <<<"$ROOT_PID $HELPERS" | grep -E '^[0-9]+$' | sort -un; }

# Đặt các biến S_* cho một lần lấy mẫu.
sample() {
    S_APP=0; S_GPU=0; S_NET=0; S_WEB=0; S_NWEB=0; S_TOTAL=0; S_CPU=0
    local pid fp cpu name
    for pid in $(all_pids); do
        fp=$(footprint_mb "$pid"); [[ -z "$fp" ]] && continue
        cpu=$(ps -o pcpu= -p "$pid" 2>/dev/null | tr -d ' '); [[ -z "$cpu" ]] && cpu=0
        name=$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)" 2>/dev/null || echo '?')
        case "$name" in
            *WebKit.GPU)        S_GPU=$(awk -v a="$S_GPU" -v b="$fp" 'BEGIN{printf "%.1f",a+b}') ;;
            *WebKit.Networking) S_NET=$(awk -v a="$S_NET" -v b="$fp" 'BEGIN{printf "%.1f",a+b}') ;;
            *WebKit.WebContent) S_WEB=$(awk -v a="$S_WEB" -v b="$fp" 'BEGIN{printf "%.1f",a+b}'); S_NWEB=$((S_NWEB+1)) ;;
            *)                  S_APP=$(awk -v a="$S_APP" -v b="$fp" 'BEGIN{printf "%.1f",a+b}') ;;
        esac
        S_TOTAL=$(awk -v a="$S_TOTAL" -v b="$fp" 'BEGIN{printf "%.1f",a+b}')
        S_CPU=$(awk -v a="$S_CPU" -v b="$cpu" 'BEGIN{printf "%.1f",a+b}')
        S_ROWS+=("$pid|$name|$fp|$cpu")
    done
}

resolve_pids || { echo "Không thấy process nào của '${APP}'. App đang chạy chưa?" >&2; exit 1; }

if [[ "$MODE" != "--watch" ]]; then
    S_ROWS=(); sample
    printf "%-8s %14s %7s  %s\n" PID "FOOTPRINT MB" "%CPU" PROCESS
    for r in "${S_ROWS[@]}"; do
        IFS='|' read -r pid name fp cpu <<<"$r"
        printf "%-8s %14s %7s  %s\n" "$pid" "$fp" "$cpu" "$name"
    done
    echo "──────────────────────────────────────────────────────────"
    printf "%-8s %14s %7s\n" TỔNG "$S_TOTAL" "$S_CPU"
    echo
    echo "attribution: $ATTRIBUTION"
    echo "Lưu ý: %CPU của ps là trung bình từ lúc process sinh ra, không phải tức thời."
    echo "       Đây là ảnh chụp 1 thời điểm — dùng --watch để thấy memory phình theo giờ."
    exit 0
fi

# ── watch mode ──
[[ -f "$CSV" ]] || echo "time,uptime_s,app_mb,gpu_mb,net_mb,webcontent_mb,n_webcontent,total_mb,cpu_pct" > "$CSV"

echo "Theo dõi mỗi ${INTERVAL}s, ghi vào $CSV. Ctrl-C để dừng."
echo "attribution: $ATTRIBUTION"
echo
printf "%-9s %9s %9s %9s %9s %5s %10s %8s\n" TIME APP GPU NET WEBCONTENT nWC TỔNG "Δ TỔNG"

BASE=""
while true; do
    # App bị relaunch → PID đổi → phải tra lại, nếu không đo process đã chết.
    if ! kill -0 "$ROOT_PID" 2>/dev/null || [[ "$(pgrep -f "${APP}.app/Contents/MacOS/" | head -1)" != "$ROOT_PID" ]]; then
        if resolve_pids; then
            echo "  → app đổi PID (relaunch), đã tra lại: $ROOT_PID"
            BASE=""   # reset mốc so sánh, process mới không so được với process cũ
        else
            echo "  → app không còn chạy, chờ..."
            sleep "$INTERVAL"; continue
        fi
    fi

    S_ROWS=(); sample
    [[ -z "$BASE" ]] && BASE="$S_TOTAL"
    delta=$(awk -v a="$S_TOTAL" -v b="$BASE" 'BEGIN{printf "%+.1f", a-b}')
    up=$(age_secs "$ROOT_PID" || echo 0)

    printf "%-9s %9s %9s %9s %9s %5s %10s %8s\n" \
        "$(date +%H:%M:%S)" "$S_APP" "$S_GPU" "$S_NET" "$S_WEB" "$S_NWEB" "$S_TOTAL" "$delta"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$up,$S_APP,$S_GPU,$S_NET,$S_WEB,$S_NWEB,$S_TOTAL,$S_CPU" >> "$CSV"

    sleep "$INTERVAL"
done
