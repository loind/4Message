#!/usr/bin/env bash
# Đo RSS + CPU của một app kể cả helper process.
#   ./measure.sh "FB Mess"
#   ./measure.sh Franz
#
# Electron helper là child process nên gom chính xác.
# WebKit XPC service (WebContent/Networking/GPU) lại do launchd spawn (ppid=1) và
# macOS không cho biết app nào sở hữu mà không có root. Nên ta gom theo heuristic:
# XPC service nào khởi động SAU app thì tính là của app. Đúng khi bạn mở app rồi đo;
# sai nếu bạn mở thêm tab Safari trong lúc đo.
set -euo pipefail

APP="${1:?Cần tên app, ví dụ: ./measure.sh \"FB Mess\"}"

root_pids=$(pgrep -f "/${APP}.app/Contents/MacOS/" || true)
if [[ -z "$root_pids" ]]; then
    echo "Không thấy process nào của '${APP}'. App đang chạy chưa?"
    exit 1
fi

# `ps` macOS chỉ có etime dạng [[dd-]hh:]mm:ss → đổi sang giây.
age_secs() {
    local e
    e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')
    [[ -z "$e" ]] && return 1
    awk -F'[-:]' '
        NF==2 { print $1*60 + $2 }
        NF==3 { print $1*3600 + $2*60 + $3 }
        NF==4 { print $1*86400 + $2*3600 + $3*60 + $4 }
    ' <<<"$e"
}

# App chạy lâu nhất trong nhóm = process gốc.
app_age=0
for pid in $root_pids; do
    age=$(age_secs "$pid") || continue
    (( age > app_age )) && app_age=$age
done

pids="$root_pids"
for pid in $root_pids; do
    children=$(pgrep -P "$pid" || true)
    [[ -n "$children" ]] && pids="$pids $children"
done

# WebKit XPC service trẻ hơn app → coi là của app.
for pid in $(pgrep -f 'com.apple.WebKit.(WebContent|Networking|GPU)' || true); do
    age=$(age_secs "$pid") || continue
    (( age <= app_age )) && pids="$pids $pid"
done

printf "%-8s %10s %7s  %s\n" PID "RSS (MB)" "%CPU" PROCESS
total_rss=0
total_cpu=0
for pid in $(tr ' ' '\n' <<<"$pids" | sort -un); do
    read -r rss cpu <<<"$(ps -o rss=,pcpu= -p "$pid" 2>/dev/null)" || continue
    [[ -z "${rss:-}" ]] && continue
    name=$(basename "$(ps -o comm= -p "$pid")")
    printf "%-8s %10.1f %7s  %s\n" "$pid" "$(bc -l <<<"$rss/1024")" "$cpu" "$name"
    total_rss=$(bc -l <<<"$total_rss + $rss")
    total_cpu=$(bc -l <<<"$total_cpu + $cpu")
done

echo "──────────────────────────────────────────────────────────"
printf "TỔNG     %10.1f %7.1f\n" "$(bc -l <<<"$total_rss/1024")" "$total_cpu"
