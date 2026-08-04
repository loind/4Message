#!/usr/bin/env bash
# Build rồi đẩy bản Electron lên GitHub Release.
#
#   ./release-electron.sh
#
# KHÔNG commit .zip vào repo: nó 114 MB mà GitHub chặn cứng push file > 100 MB, và mỗi bản
# build sẽ nằm vĩnh viễn trong git history. Release asset không vào history, giới hạn 2 GB.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=FBMessElectron
REPO=loind/CustomMess

command -v gh >/dev/null || { echo "cần gh CLI: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh chưa login: gh auth login"; exit 1; }

# Release phải tra được về đúng một commit. Cây còn thay đổi thì bundle mang cờ DIRTY và
# không ai biết nó là code nào.
[ -z "$(git status --porcelain)" ] || { echo "cây làm việc còn thay đổi chưa commit"; exit 1; }

BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)
TAG="electron-b$BUILD"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "release $TAG đã có. Commit thêm rồi release lại — số build đi theo số commit."
  exit 1
fi

./build-electron.sh

ELECTRON_VER=$(node -p "require('./electron/package.json').devDependencies.electron")
gh release create "$TAG" "$APP_NAME-arm64.tar.xz" --repo "$REPO" \
  --title "Electron build $BUILD" \
  --notes "commit \`$COMMIT\` · electron $ELECTRON_VER · arm64

Cài trên máy dùng: \`./install-electron.sh\`"

echo "→ $(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
