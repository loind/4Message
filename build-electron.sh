#!/usr/bin/env bash
# Build bản Electron thành .app dùng được.
#
#   ./build-electron.sh          # → "FB Mess Electron.app" ở gốc repo
#   ./build-electron.sh --run    # build xong mở luôn
#
# Session store nằm ở ~/Library/Application Support/FB Mess Electron/ — TÁCH RIÊNG với bản
# Swift (~/Library/WebKit/...). Cookie không chuyển được, phải login lại trong app này, và
# mỗi lần login là một device E2EE mới nên lịch sử chat mã hoá không theo sang.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FB Mess Electron"
SRC=electron
CACHE="${NPM_CACHE:-$TMPDIR/fbmess-npm-cache}"

command -v node >/dev/null || { echo "cần node"; exit 1; }
[ -f Resources/AppIcon.icns ] || ./make-icon.sh

# build-info.json phải sinh TRƯỚC khi package, không thì bundle mang info của lần build cũ.
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
DIRTY=false
[ -z "$(git status --porcelain 2>/dev/null)" ] || DIRTY=true
node -e "
  require('fs').writeFileSync('$SRC/build-info.json', JSON.stringify({
    commit: '$COMMIT', dirty: $DIRTY, built: new Date().toISOString(),
  }, null, 2) + '\n')
"
echo "build-info: $COMMIT dirty=$DIRTY"

[ -d "$SRC/node_modules/electron" ] || (cd "$SRC" && npm install --cache "$CACHE" --save-dev electron)
node "$SRC/selftest.js"

rm -rf "$APP_NAME.app"
(cd "$SRC" && npx --yes --cache "$CACHE" @electron/packager . "$APP_NAME" \
  --platform=darwin --arch="${FBMESS_ARCH:-arm64}" --out=../build-electron --overwrite \
  --app-bundle-id=io.mobio.fbmess.electron \
  --icon=../Resources/AppIcon.icns 2>&1 | tail -5)

mv "build-electron/$APP_NAME-darwin-${FBMESS_ARCH:-arm64}/$APP_NAME.app" .
rm -rf build-electron

# Ad-hoc sign: không sign thì Gatekeeper chặn và các entitlement (notification) im lặng fail.
codesign --force --deep --sign - "$APP_NAME.app" 2>/dev/null || echo "cảnh báo: codesign fail"

echo "→ $(pwd)/$APP_NAME.app"
"./$APP_NAME.app/Contents/MacOS/$APP_NAME" --version || true
[ "${1:-}" = "--run" ] && open "$APP_NAME.app"
