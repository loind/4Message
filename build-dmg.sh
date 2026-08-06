#!/usr/bin/env bash
# Đóng 4Message.app thành DMG kiểu Apple: mở ra thấy app cạnh shortcut Applications,
# kéo sang là cài.
#
#   ./build-dmg.sh          # build app nếu chưa có, rồi đóng DMG
#   ./build-dmg.sh --keep   # dùng .app đang có, không build lại
#
# KHÔNG giải quyết prompt Gatekeeper. Prompt đó do cờ com.apple.quarantine mà browser gắn
# khi tải, và chỉ Developer ID + notarize mới bỏ được — xem README mục "Cài đặt".
# DMG chỉ làm bước cài đúng chuẩn, không đổi trạng thái ký.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=4Message
APP="$APP_NAME.app"
VOL="$APP_NAME"
DMG="$APP_NAME-arm64.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"; hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true' EXIT

[ "${1:-}" = "--keep" ] || ./build-electron.sh >/dev/null
[ -d "$APP" ] || { echo "không có $APP — chạy ./build-electron.sh trước"; exit 1; }

# codesign/spctl hiểu đối số bắt đầu bằng chữ số là PID, nên "4Message.app" ra
# "No such process". Luôn dùng ./ cho tên app này.
codesign --verify --deep --strict "./$APP" || { echo "signature không hợp lệ"; exit 1; }

BUILD=$(node -p "require('./electron/build-info.json').build" 2>/dev/null || echo '?')
echo "đóng DMG cho build $BUILD"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# .background phải là thư mục ẩn, không thì nó hiện thành một item trong cửa sổ DMG.
mkdir -p "$STAGE/.background"
[ -f build-icon/dmg-bg.png ] && cp build-icon/dmg-bg.png "$STAGE/.background/bg.png"

rm -f "$DMG" rw.dmg
# Dựng ảnh RW trước để còn sửa được layout Finder, xong mới nén sang RO.
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
    -format UDRW -ov -quiet rw.dmg
hdiutil attach rw.dmg -readwrite -noverify -noautoopen -quiet
sleep 2

# Layout cửa sổ: app bên trái, mũi tên kéo sang Applications bên phải. Toạ độ icon phải
# đặt bằng AppleScript — hdiutil không có API cho .DS_Store.
# Best-effort: Finder automation cần GUI session thật. Máy build headless sẽ timeout —
# khi đó bỏ layout và vẫn ra DMG dùng được (app + shortcut Applications vẫn đúng), chỉ
# thiếu vị trí icon và ảnh nền. Không để bước trang trí chặn bước đóng gói.
osascript >/dev/null 2>&1 <<OSA || echo "  bỏ qua layout Finder (không có GUI session)"
with timeout of 25 seconds
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 800, 520}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    try
      set background picture of opts to file ".background:bg.png"
    end try
    set position of item "$APP" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
end timeout
OSA

sync
hdiutil detach "/Volumes/$VOL" -quiet
hdiutil convert rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f rw.dmg

# Ký cả DMG: không bỏ được prompt, nhưng chữ ký hợp lệ thì macOS không thêm cảnh báo
# "damaged" khi file bị sửa trên đường truyền.
codesign --force --sign - "./$DMG" 2>/dev/null || echo "cảnh báo: không ký được DMG"

echo "→ $(pwd)/$DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
hdiutil verify "$DMG" >/dev/null && echo "  hdiutil verify: OK"
