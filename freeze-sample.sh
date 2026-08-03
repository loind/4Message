#!/usr/bin/env bash
# Chụp stack trace của WebContent process ĐÚNG lúc nội dung đóng băng.
#
#   ./freeze-sample.sh            # chạy ngay lúc đang treo
#   SECONDS_TO_SAMPLE=10 ./freeze-sample.sh
#
# Hai lỗi của cách làm tay trước đó, script này sửa:
#   1. `pgrep com.apple.WebKit.WebContent | head -1` lấy WebContent ĐẦU TIÊN trên máy,
#      thường là của Safari chứ không phải của app. Attribution phải qua unified log.
#   2. Grep theo từ khoá đoán trước (Selector, page_fault) — nếu nguyên nhân là thứ khác
#      thì grep rỗng và không học được gì. Script in stack NẶNG NHẤT, không lọc theo
#      giả thuyết.
set -uo pipefail
cd "$(dirname "$0")"

APP_NAME="${1:-FB Mess}"
DUR="${SECONDS_TO_SAMPLE:-5}"
OUT=$(mktemp /tmp/fbmess-freeze-XXXX.txt)

root=$(pgrep -f "${APP_NAME}.app/Contents/MacOS/" | head -1 || true)
[[ -z "$root" ]] && { echo "Không thấy app '${APP_NAME}' đang chạy." >&2; exit 1; }

exec_name=$(basename "$(ps -o comm= -p "$root")")
uptime_s=$(ps -o etime= -p "$root" | tr -d ' ' \
  | awk -F'[-:]' 'NF==2{print $1*60+$2} NF==3{print $1*3600+$2*60+$3} NF==4{print $1*86400+$2*3600+$3*60+$4}')
# Cửa sổ log NGẮN: `log show --last 180m` quét 3 tiếng log và treo hàng phút. Helper chỉ
# log lúc launch, nên nếu app chạy lâu thì cách này miss — đã có fallback bên dưới.
win_min=10

# WebContent của app này, theo unified log (macOS gán log XPC service về app chịu trách nhiệm).
# Dùng string chứ không dùng `mapfile`: macOS ship bash 3.2, không có mapfile.
webs=$(/usr/bin/log show --predicate "process == \"$exec_name\"" --last "${win_min}m" 2>/dev/null \
  | grep -oE 'WebContent\[[0-9]+\]' | grep -oE '[0-9]+' | sort -un | tr '\n' ' ')
method="unified log"
if [[ -z "${webs// /}" ]]; then
    # Fallback: WebContent sinh SAU app. Có thể bắt nhầm của app khác, nên in PID ra để
    # đối chiếu với measure.sh trước khi tin.
    method="heuristic (trẻ hơn app) — ĐỐI CHIẾU với ./measure.sh"
    webs=""
    for p in $(pgrep -f 'com.apple.WebKit.WebContent' 2>/dev/null); do
        a=$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ' \
            | awk -F'[-:]' 'NF==2{print $1*60+$2} NF==3{print $1*3600+$2*60+$3} NF==4{print $1*86400+$2*3600+$3*60+$4}')
        [[ -n "$a" ]] && (( a <= uptime_s )) && webs="$webs $p"
    done
fi
[[ -z "${webs// /}" ]] && { echo "Không tìm được WebContent nào." >&2; exit 1; }

# Chọn cái nặng nhất — đó là process render trang, không phải worker.
best=""; best_mb=0
for p in $webs; do
    kill -0 "$p" 2>/dev/null || continue
    b=$(/usr/bin/footprint --json "$OUT.json" "$p" >/dev/null 2>&1 \
        && plutil -extract processes.0.footprint raw -o - "$OUT.json" 2>/dev/null || echo 0)
    mb=$(awk -v v="${b:-0}" 'BEGIN{printf "%d", v/1048576}')
    (( mb > best_mb )) && { best_mb=$mb; best=$p; }
done
[[ -z "$best" ]] && { echo "WebContent không còn sống." >&2; exit 1; }

echo "app pid=$root · WebContent pid=$best (${best_mb} MB) · sample ${DUR}s"
echo "attribution: $method"
echo "CPU ngay lúc này: $(ps -o pcpu= -p "$best" | tr -d ' ')%"
echo "pressure level  : $(sysctl -n kern.memorystatus_vm_pressure_level)  (1=normal 2=warn 4=critical)"
echo

sample "$best" "$DUR" -file "$OUT" >/dev/null 2>&1 || { echo "sample thất bại" >&2; exit 1; }

echo "════ stack NẶNG NHẤT (không lọc theo giả thuyết) ════"
# `sample` in phần "Sort by top of stack" ở cuối — đó là nơi thời gian thực sự bị tiêu.
awk '/Sort by top of stack/,0' "$OUT" | head -25

echo
echo "════ thread chính của WebContent ════"
awk '/^  Thread_/{n++} n==1' "$OUT" | head -22

echo
echo "full: $OUT"
