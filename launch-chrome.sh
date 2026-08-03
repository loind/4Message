#!/usr/bin/env bash
# Hướng B: mở kênh chat trong Chrome app mode. 0 dòng code app, dùng Blink thật.
#
#   ./launch-chrome.sh                 # Messenger
#   ./launch-chrome.sh instagram
#   ./launch-chrome.sh threads
#
# MẤT so với app native: menu bar resident, ⌘⇧M global hotkey, badge unread trên dock,
# rail đa kênh, và app không còn là một process 28 MB — Chrome tự quản lý RAM của nó.
#
# Chrome PHẢI đang tắt: `--args` chỉ có tác dụng ở lần launch đầu, và `open -na` tạo
# instance thứ hai bị kẹt profile lock (Chrome chạy mà 0 cửa sổ).
set -uo pipefail

case "${1:-messenger}" in
    messenger) URL='https://www.facebook.com/messages/' ;;
    instagram) URL='https://www.instagram.com/direct/inbox/' ;;
    threads)   URL='https://www.threads.com/messages/' ;;
    *)         URL="$1" ;;
esac

if pgrep -x 'Google Chrome' >/dev/null; then
    echo "⚠ Chrome đang chạy → --args bị bỏ qua, sẽ mở tab thường chứ không phải app mode."
    echo "  Đóng Chrome (⌘Q) rồi chạy lại nếu muốn cửa sổ app mode thật."
fi

echo "→ $URL"
open -a "Google Chrome" --args --app="$URL"
