#!/usr/bin/env bash
# Sinh Resources/AppIcon.icns từ tools/make-icon.swift.
# Chạy lại khi sửa thiết kế icon; build-electron.sh tự gọi nếu thiếu file .icns.
set -euo pipefail
cd "$(dirname "$0")"

WORK=build-icon
rm -rf "$WORK"
mkdir -p "$WORK" Resources

swift tools/make-icon.swift "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns

echo "✓ Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1 | tr -d ' '))"
echo "  xem trước 1024px: $WORK/icon-preview.png"
