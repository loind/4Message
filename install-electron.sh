#!/usr/bin/env bash
# Cài bản mới nhất từ GitHub Release. Chạy trên MÁY DÙNG, không cần node.
#
#   ./install-electron.sh
set -euo pipefail

APP_NAME=4Message
APP=/Applications/$APP_NAME.app
REPO=loind/4Message

command -v gh >/dev/null || { echo "cần gh CLI: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh chưa login: gh auth login"; exit 1; }

TMP=$(mktemp -d)
MNT="$TMP/mnt"
# Detach trong trap: DMG còn mount thì lần chạy sau đụng volume cũ, và người dùng phải
# tự eject bằng tay.
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Tải bằng gh, KHÔNG bằng browser: file browser tải bị gắn com.apple.quarantine nên
# Gatekeeper chặn (bundle chỉ ad-hoc sign), phải xattr -dr mới mở được. gh chỉ gắn
# com.apple.provenance — không phải cờ Gatekeeper. Đã kiểm chứng.
gh release download --repo "$REPO" --pattern '*.dmg' --dir "$TMP"
DMG=$(ls "$TMP"/*.dmg | head -1)

# -mountpoint vào thư mục tạm + -nobrowse: không đụng /Volumes nên không xung đột nếu đã
# có volume cùng tên đang mount, và không hiện lên Finder giữa lúc cài.
mkdir -p "$MNT"
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -quiet -mountpoint "$MNT"
[ -d "$MNT/$APP_NAME.app" ] || { echo "DMG không chứa $APP_NAME.app"; exit 1; }

# ./ hoặc đường dẫn tuyệt đối là bắt buộc: codesign hiểu đối số bắt đầu bằng chữ số là
# PID, nên "4Message.app" trả "No such process" thay vì kiểm signature.
codesign --verify --deep --strict "$MNT/$APP_NAME.app" || {
    echo "signature trong DMG không hợp lệ — dừng, không cài"; exit 1; }

"$MNT/$APP_NAME.app/Contents/MacOS/$APP_NAME" --version

# Quit TRƯỚC khi ghi đè: copy lên một .app đang chạy làm hỏng instance đang chạy.
# Không mất gì — session ở ~/Library/Application Support/, không nằm trong bundle.
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1

rm -rf "$APP"
cp -R "$MNT/$APP_NAME.app" /Applications/
hdiutil detach "$MNT" -quiet
open "$APP"
echo "→ $APP"
