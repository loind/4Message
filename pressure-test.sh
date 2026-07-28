#!/usr/bin/env bash
# Kiểm chứng: WebKit có tự purge cache khi hệ thống báo memory pressure?
#
# Nếu CÓ → ~800 MB chỉ là cache, OS lấy lại được khi cần, không cần fix gì.
# Nếu KHÔNG → memory bị giữ thật, cần tạo lại WKWebView mới trả về được.
#
#   sudo ./pressure-test.sh
#
# Dùng `memory_pressure -S` = SIMULATE, không cấp phát RAM thật.
# (`memory_pressure -l warn` mà thiếu -S sẽ ăn nhiều GB RAM thật → không dùng.)
# Trap reset sysctl về normal kể cả khi Ctrl-C, để máy không kẹt ở pressure.
# HẠN CHẾ ĐÃ BIẾT (chưa sửa — measure.sh đã sửa, script này chưa):
#   1. Parse text `vmmap` nên trên 1 GB độ phân giải chỉ 100 MB. Dòng "1.2G" giữ nguyên
#      qua các mốc KHÔNG chứng minh được là không giảm.
#   2. Attribution dùng "WebKit process trẻ hơn app" nên gom cả WebContent của app khác
#      (Safari/Slack). Trên máy nhiều app WebKit, process "bị kill" có thể không phải của app.
# Muốn kết quả tin được: chuyển sang `footprint --json` + attribution qua unified log,
# giống measure.sh.

set -uo pipefail
cd "$(dirname "$0")"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Cần chạy: sudo ./pressure-test.sh" >&2; exit 1; }

SYSCTL=kern.memorypressure_manual_trigger
reset_pressure() {
    sysctl -w "$SYSCTL"=1 >/dev/null 2>&1 || true   # 1 = NORMAL
    echo "  [đã reset memory pressure về normal]"
}
trap reset_pressure EXIT INT TERM

fp() { vmmap --summary "$1" 2>/dev/null | awk -F: '/Physical footprint:/{gsub(/ /,"",$2); print $2; exit}'; }

age() {
    local e
    e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')
    [[ -z "$e" ]] && return 1
    awk -F'[-:]' 'NF==2{print $1*60+$2} NF==3{print $1*3600+$2*60+$3} NF==4{print $1*86400+$2*3600+$3*60+$4}' <<<"$e"
}

APP=$(pgrep -f 'FB Mess\.app/Contents/MacOS/Messenger' | head -1)
[[ -n "$APP" ]] || { echo "App chưa chạy — mở app rồi chạy lại." >&2; exit 1; }
AAGE=$(age "$APP") || exit 1

# WebKit XPC service của app = process trẻ hơn app (chúng có ppid=1 nên không
# gom được bằng quan hệ cha-con).
PIDS="$APP"
for p in $(pgrep -f 'com.apple.WebKit.(WebContent|Networking|GPU)' 2>/dev/null); do
    a=$(age "$p") || continue
    (( a <= AAGE )) && PIDS="$PIDS $p"
done

label() { ps -o comm= -p "$1" 2>/dev/null | xargs basename 2>/dev/null; }

snapshot() {
    local total=0 p v
    for p in $PIDS; do
        v=$(fp "$p"); [[ -z "$v" ]] && continue
        printf "    %-6s %-30s %9s\n" "$p" "$(label "$p")" "$v"
        total=$(awk -v t="$total" -v s="$v" 'BEGIN{u=substr(s,length(s));n=s+0;
            if(u=="G")n*=1024; else if(u=="K")n/=1024; printf "%.1f", t+n}')
    done
    printf "    %-38s %8s MB\n" "TỔNG" "$total"
}

hold_pressure() {   # $1 = warn|critical, $2 = giây
    memory_pressure -S -l "$1" -Q >/dev/null 2>&1 &
    local mp=$!
    sleep "$2"
    kill "$mp" 2>/dev/null || true
    wait "$mp" 2>/dev/null || true
}

echo "PID theo dõi: $PIDS"
echo
echo "① TRƯỚC (không pressure)"; snapshot

echo
echo "② Simulate WARN 30s..."
hold_pressure warn 30
snapshot

echo
echo "③ Simulate CRITICAL 20s..."
hold_pressure critical 20
snapshot

echo
echo "④ Sau khi thả pressure, chờ 20s"
sleep 20
snapshot
