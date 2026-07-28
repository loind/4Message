#!/usr/bin/env bash
# Đo memory + CPU của app kể cả helper process.
#   ./measure.sh "FB Mess"
#
# Báo `phys_footprint` — CHÍNH LÀ số ở cột Memory của Activity Monitor.
# Không dùng RSS: nó bỏ qua phần memory đã bị nén, nên báo thiếu (đo được 348 MB RSS
# cho process mà Activity Monitor báo 1.35 GB). RSS cũng gộp trang code framework dùng
# chung với Safari nên ở chiều khác lại báo thừa. Cả hai chiều đều sai.
#
# Attribution lấy từ unified log: macOS gán log của WebKit XPC service về app chịu
# trách nhiệm. Chính xác hơn heuristic "process trẻ hơn app" — heuristic đó gom cả
# WebContent của app khác (Safari, Slack) nếu chúng khởi động sau.
set -uo pipefail

APP="${1:?Cần tên app, ví dụ: ./measure.sh \"FB Mess\"}"

root_pids=$(pgrep -f "${APP}.app/Contents/MacOS/" || true)
if [[ -z "$root_pids" ]]; then
    echo "Không thấy process nào của '${APP}'. App đang chạy chưa?" >&2
    exit 1
fi

exec_name=$(basename "$(ps -o comm= -p "$(head -1 <<<"$root_pids")")")

# Cửa sổ log phải phủ từ lúc app launch: GPU và Networking chỉ log khi khởi động,
# cửa sổ ngắn hơn uptime là mất chúng (đo thiếu ~32 MB). Cap 180 phút cho khỏi chậm.
uptime_min=$(ps -o etime= -p "$(head -1 <<<"$root_pids")" | tr -d ' ' \
    | awk -F'[-:]' 'NF==2{print int(($1*60+$2)/60)+1} NF==3{print int(($1*3600+$2*60+$3)/60)+1} NF==4{print int(($1*86400+$2*3600+$3*60+$4)/60)+1}')
(( uptime_min > 180 )) && uptime_min=180
(( uptime_min < 5 )) && uptime_min=5

# WebKit XPC service của app, theo unified log.
helper_pids=$(/usr/bin/log show --predicate "process == \"$exec_name\"" --last "${uptime_min}m" 2>/dev/null \
    | grep -oE '(WebContent|GPU|Networking)\[[0-9]+\]' \
    | grep -oE '[0-9]+' | sort -un || true)

age_secs() {
    local e
    e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')
    [[ -z "$e" ]] && return 1
    awk -F'[-:]' 'NF==2{print $1*60+$2} NF==3{print $1*3600+$2*60+$3} NF==4{print $1*86400+$2*3600+$3*60+$4}' <<<"$e"
}

# Log chỉ ghi PID của WebContent, không ghi GPU/Networking. Nhận chúng bằng heuristic
# HẸP: sinh ra trong vòng 20s quanh lúc app launch. Khác với "trẻ hơn app" — cái đó
# gom cả WebContent của Safari/Slack khởi động sau, đo thừa hàng trăm MB.
attribution="unified log (WebContent) + cùng thời điểm launch (GPU/Networking)"
app_age=$(age_secs "$(head -1 <<<"$root_pids")" || echo 0)
for p in $(pgrep -f 'com.apple.WebKit.(GPU|Networking)' 2>/dev/null || true); do
    a=$(age_secs "$p") || continue
    d=$(( app_age > a ? app_age - a : a - app_age ))
    (( d <= 20 )) && helper_pids="$helper_pids $p"
done

if [[ -z "${helper_pids// /}" ]]; then
    # Fallback: process con trực tiếp (đúng cho Electron; WebKit XPC có ppid=1 nên
    # thường không bắt được). Kém chính xác — cảnh báo rõ.
    attribution="fallback: child process (KÉM CHÍNH XÁC, có thể thiếu WebKit XPC)"
    for pid in $root_pids; do
        helper_pids="$helper_pids $(pgrep -P "$pid" 2>/dev/null || true)"
    done
fi

footprint_mb() {
    vmmap --summary "$1" 2>/dev/null | awk -F: '/Physical footprint:/{
        gsub(/ /,"",$2); v=$2
        u=substr(v,length(v)); n=v+0
        if (u=="G") n*=1024; else if (u=="K") n/=1024
        printf "%.1f", n
    }'
}

printf "%-8s %14s %7s  %s\n" PID "FOOTPRINT MB" "%CPU" PROCESS
total=0
cpu_total=0
for pid in $(tr ' ' '\n' <<<"$root_pids $helper_pids" | grep -E '^[0-9]+$' | sort -un); do
    fp=$(footprint_mb "$pid")
    [[ -z "$fp" ]] && continue
    cpu=$(ps -o pcpu= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$cpu" ]] && cpu=0
    printf "%-8s %14s %7s  %s\n" "$pid" "$fp" "$cpu" "$(basename "$(ps -o comm= -p "$pid")")"
    total=$(awk -v a="$total" -v b="$fp" 'BEGIN{printf "%.1f", a+b}')
    cpu_total=$(awk -v a="$cpu_total" -v b="$cpu" 'BEGIN{printf "%.1f", a+b}')
done

echo "──────────────────────────────────────────────────────────"
printf "%-8s %14s %7s\n" TỔNG "$total" "$cpu_total"
echo
echo "attribution: $attribution"
echo "Lưu ý: %CPU của ps là trung bình từ lúc process sinh ra, không phải tức thời."
echo "       Cần CPU tức thời thì dùng ./bench.sh (lấy mẫu qua cửa sổ thời gian)."
