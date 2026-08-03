#!/usr/bin/env bash
# Đo CPU của Chrome khi render cùng trang Messenger, để so với WKWebView.
#
#   ./chrome-probe.sh
#   URL=https://www.instagram.com/direct/inbox/ ./chrome-probe.sh
#
# Chạy trên máy CÓ LỖI (MacBook), nơi Chrome đã login Facebook sẵn.
#
# Hai lỗi đã mắc khi làm tay, script này sửa:
#   1. `pgrep -f 'Helper (Renderer)'` — ngoặc là regex group nên pattern sai; và kể cả
#      escape đúng thì nó khớp CẢ renderer của Bitwarden/Orca/Edge (mọi app Electron).
#      Phải match theo đường dẫn `/Google Chrome.app/`.
#   2. `open -na` tạo instance thứ hai → kẹt profile lock, Chrome chạy mà 0 cửa sổ.
#      Phải bảo đảm Chrome đã tắt rồi launch bằng profile thật.
#
# Và bắt buộc xác nhận cửa sổ có thật + đúng trang: một renderer 0% CPU có thể chỉ là
# tab nền, hoặc trang login — số đo lúc đó vô nghĩa.
set -uo pipefail

URL="${URL:-https://www.facebook.com/messages/}"
SAMPLES="${SAMPLES:-8}"
GAP="${GAP:-5}"

chrome_renderers() {
    # CHỈ renderer của Chrome. `Helper (Renderer)` trần khớp mọi app Electron
    # (đã đo nhầm renderer của Bitwarden và Orca vì lỗi này).
    #
    # `[G]oogle` — bracket trick: nếu viết thẳng thì `ps` bắt luôn chính các process
    # `grep` trong pipeline (args của chúng chứa pattern), đếm ra 3 renderer trong khi
    # Chrome đang tắt hẳn.
    ps -Ao pid=,args= \
      | grep '/[G]oogle Chrome.app/' | grep 'Helper (Renderer)' \
      | awk '{print $1}'
}

if pgrep -x 'Google Chrome' >/dev/null; then
    echo "Chrome đang chạy. Cần TẮT hẳn để launch được với --app bằng profile thật."
    echo "Đóng Chrome (⌘Q) rồi chạy lại. Đang mở tab quan trọng thì đo sau."
    exit 1
fi

before=$(chrome_renderers | tr '\n' ' ')
echo "→ launch Chrome app mode: $URL"
open -a "Google Chrome" --args --app="$URL"
sleep 45

main=$(pgrep -x 'Google Chrome' | head -1)
[[ -z "$main" ]] && { echo "✗ Chrome không chạy." >&2; exit 1; }

# Cửa sổ phải tồn tại. Không có cửa sổ = trang chưa render = số đo vô nghĩa.
wins=$(osascript -e 'tell application "System Events" to tell process "Google Chrome" to get count of windows' 2>/dev/null || echo 0)
echo "  cửa sổ: $wins"
if [[ "$wins" == "0" ]]; then
    echo "✗ Chrome 0 cửa sổ — trang chưa render. Không đo." >&2
    echo "  Thường do còn instance Chrome khác giữ profile lock." >&2
    exit 1
fi

best=""; best_mb=0
for p in $(chrome_renderers); do
    grep -q " $p " <<<" $before " && continue     # renderer có từ trước, không phải của ta
    f=$(vmmap --summary "$p" 2>/dev/null | awk -F: '/Physical footprint:/{gsub(/[^0-9.]/,"",$2); print int($2)}')
    [[ -n "$f" ]] && (( f > best_mb )) && { best_mb=$f; best=$p; }
done
[[ -z "$best" ]] && { echo "✗ Không thấy renderer mới của Chrome." >&2; exit 1; }

echo "  renderer=$best  footprint=${best_mb} MB"
if (( best_mb < 150 )); then
    echo "  ⚠ footprint nhỏ — có thể đang ở trang LOGIN chứ không phải Messenger."
    echo "    Đăng nhập trong cửa sổ đó rồi chạy lại script."
fi

cpu_secs() {
    ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ' \
      | awk -F'[:.]' '{ if (NF>=3) print $1*60+$2"."$3; else print $1"."$2 }'
}

echo
echo "── CPU tức thời (delta cputime / ${GAP}s) ──"
echo "   WKWebView đo được:  4.0 · 3.6 · 18.4 · 60.6 · 4.0 · 3.6 · 3.6 · 3.4  (%)"
echo
prev=$(cpu_secs "$best")
peak=0
for i in $(seq 1 "$SAMPLES"); do
    sleep "$GAP"
    cur=$(cpu_secs "$best")
    [[ -z "$cur" ]] && { echo "  renderer chết"; break; }
    v=$(awk -v a="$prev" -v b="$cur" -v g="$GAP" 'BEGIN{printf "%.1f", (b-a)/g*100}')
    printf "  %2d: %5s%%\n" "$i" "$v"
    awk -v v="$v" -v p="$peak" 'BEGIN{exit !(v>p)}' && peak=$v
    prev=$cur
done

echo
echo "peak Chrome = ${peak}%   ·   peak WKWebView = 60.6%"
echo "Chrome peak thấp hơn nhiều  → engine là nguyên nhân, bàn tiếp phương án B/C."
echo "Chrome cũng spike tương tự  → là web app của Facebook, KHÔNG engine nào chữa."
