#!/usr/bin/env bash
# Cài bản Electron mới nhất từ GitHub Release. Chạy trên MÁY DÙNG, không cần node.
#
#   ./install-electron.sh
set -euo pipefail

APP_NAME=4Messenge
APP=/Applications/$APP_NAME.app
REPO=loind/CustomMess

command -v gh >/dev/null || { echo "cần gh CLI: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh chưa login: gh auth login"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Tải bằng gh, KHÔNG bằng browser: file browser tải bị gắn com.apple.quarantine nên
# Gatekeeper chặn (bundle chỉ ad-hoc sign), phải xattr -dr mới mở được. gh chỉ gắn
# com.apple.provenance — không phải cờ Gatekeeper. Đã kiểm chứng.
gh release download --repo "$REPO" --pattern '*.tar.xz' --dir "$TMP"
# -xJf: bsdtar của macOS có liblzma sẵn, không cần cài binary xz.
tar -xJf "$TMP"/*.tar.xz -C "$TMP"
[ -d "$TMP/$APP_NAME.app" ] || { echo "zip không chứa $APP_NAME.app"; exit 1; }

"$TMP/$APP_NAME.app/Contents/MacOS/$APP_NAME" --version

# Quit TRƯỚC khi ghi đè: copy lên một .app đang chạy làm hỏng instance đang chạy.
# Không mất gì — session ở ~/Library/Application Support/, không nằm trong bundle.
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1

rm -rf "$APP"
cp -R "$TMP/$APP_NAME.app" /Applications/
open "$APP"
echo "→ $APP"
