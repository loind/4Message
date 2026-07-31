#!/usr/bin/env bash
# Render rail ra PNG (light + dark) dùng đúng code của app.
#
# Compile kèm RailView.swift + Services.swift để KHÔNG dựng lại UI — preview tự dựng lại
# từng che mất lỗi layout thật (tile dính liền nhau).
#
# Phải copy sang tên main.swift: swiftc chỉ cho top-level code trong file tên đó khi
# compile nhiều file.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-rail.png}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp tools/preview-rail.swift "$TMP/main.swift"
swiftc -O -o "$TMP/preview" "$TMP/main.swift" Sources/Messenger/RailView.swift Sources/Messenger/Services.swift
"$TMP/preview" "$OUT"
