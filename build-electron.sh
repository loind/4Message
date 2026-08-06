#!/usr/bin/env bash
# Build bản Electron thành .app dùng được.
#
#   ./build-electron.sh          # → 4Message.app + .zip ở gốc repo
#   ./build-electron.sh --run    # build xong mở luôn
#
# Session store nằm ở ~/Library/Application Support/4Message/ — TÁCH RIÊNG với bản
# Swift (~/Library/WebKit/...). Cookie không chuyển được, phải login lại trong app này, và
# mỗi lần login là một device E2EE mới nên lịch sử chat mã hoá không theo sang.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=4Message
SRC=electron
CACHE="${NPM_CACHE:-$TMPDIR/fbmess-npm-cache}"
ARCH="${FBMESS_ARCH:-arm64}"
ARCHIVE="$APP_NAME-$ARCH.tar.xz"

command -v node >/dev/null || { echo "cần node"; exit 1; }
[ -f Resources/AppIcon.icns ] || ./make-icon.sh

# build-info.json phải sinh TRƯỚC khi package, không thì bundle mang info của lần build cũ.
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
# Số build = số commit. Đơn điệu tăng, tra được về đúng một commit, và không cần file
# version riêng để quên cập nhật.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
DIRTY=false
[ -z "$(git status --porcelain 2>/dev/null)" ] || DIRTY=true
node -e "
  require('fs').writeFileSync('$SRC/build-info.json', JSON.stringify({
    build: $BUILD, commit: '$COMMIT', dirty: $DIRTY, built: new Date().toISOString(),
  }, null, 2) + '\n')
"
echo "build-info: build $BUILD · $COMMIT dirty=$DIRTY"

[ -d "$SRC/node_modules/electron" ] || (cd "$SRC" && npm install --cache "$CACHE" --save-dev electron)
node "$SRC/selftest.js"

rm -rf "$APP_NAME.app" "$ARCHIVE"
(cd "$SRC" && npx --yes --cache "$CACHE" @electron/packager . "$APP_NAME" \
  --platform=darwin --arch="$ARCH" --out=../build-electron --overwrite \
  --app-bundle-id=io.mobio.fbmess.electron \
  --icon=../Resources/AppIcon.icns 2>&1 | tail -5)

mv "build-electron/$APP_NAME-darwin-$ARCH/$APP_NAME.app" .
rm -rf build-electron

# Cắt locale pak của Chromium: 218 thứ tiếng không dùng = 45 MB. Giữ en (fallback của
# Chromium khi thiếu locale hệ thống) + vi. Ảnh hưởng chỉ tới UI có sẵn của Chromium
# (context menu, spellcheck), không tới nội dung trang hay UI của app.
# PHẢI xoá TRƯỚC codesign — sửa nội dung bundle sau khi sign làm signature vỡ.
LOCALES="$APP_NAME.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources"
find "$LOCALES" -maxdepth 1 -name '*.lproj' ! -name 'en.lproj' ! -name 'vi.lproj' \
  -exec rm -rf {} + 2>/dev/null || true

# Ad-hoc sign: không sign thì Gatekeeper chặn và các entitlement (notification) im lặng fail.
# ./ là bắt buộc: codesign hiểu đối số bắt đầu bằng chữ số là PID, nên "4Message.app"
# trả "No such process" thay vì ký. Và KHÔNG chôn stderr — lỗi ký từng bị ẩn mất.
codesign --force --deep --sign - "./$APP_NAME.app" || echo "cảnh báo: codesign fail"
codesign --verify --deep --strict "./$APP_NAME.app" || echo "cảnh báo: signature không hợp lệ"

# tar.xz thay vì zip: 70 MB so với 102 MB trên cùng bundle — nhị phân Chromium nén lzma
# tốt hơn deflate rõ rệt. Giải nén bằng `tar -xJf`, bsdtar của macOS có liblzma sẵn nên máy
# đích không cần cài gì. Đã kiểm vòng nén/giải: codesign --verify --deep --strict pass.
if command -v xz >/dev/null; then
  tar -cf - "$APP_NAME.app" | xz -T0 -6 > "$ARCHIVE"    # -T0 song song: 13s
else
  tar -cJf "$ARCHIVE" "$APP_NAME.app"                    # bsdtar đơn luồng: ~58s
fi

echo "→ $(pwd)/$APP_NAME.app"
echo "→ $(pwd)/$ARCHIVE ($(du -h "$ARCHIVE" | cut -f1 | tr -d ' '))"
"./$APP_NAME.app/Contents/MacOS/$APP_NAME" --version || true
if [ "${1:-}" = "--run" ]; then open "$APP_NAME.app"; fi
