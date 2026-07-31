#!/usr/bin/env bash
# Docs không được lệch code. Kiểm tra mọi env var FBMESS_* và mọi script đều được nhắc
# trong README hoặc docs/.
#
# Tồn tại vì lần rà tay đầu tiên phát hiện 4 chỗ thiếu: FBMESS_UA, FBMESS_CONTENT_MODE,
# FBMESS_WINDOW và make-icon.sh.
set -uo pipefail
cd "$(dirname "$0")"

fail=0
say() { printf '  %s\n' "$1"; }

echo "── env var trong code mà docs chưa nhắc ──"
for v in $(grep -rhoE 'FBMESS_[A-Z_]+' Sources/ | sort -u); do
    grep -rq "$v" README.md docs/ 2>/dev/null || { say "THIẾU: $v"; fail=1; }
done

echo "── script trong repo mà docs chưa nhắc ──"
for f in *.sh; do
    [[ "$f" == "docs-check.sh" ]] && continue
    grep -rq "$f" README.md docs/ 2>/dev/null || { say "THIẾU: $f"; fail=1; }
done

echo "── docs nhắc env var không tồn tại trong code ──"
for v in $(grep -rhoE 'FBMESS_[A-Z_]+' README.md docs/ 2>/dev/null | sort -u); do
    grep -rq "$v" Sources/ || { say "docs nhắc nhưng code không có: $v"; fail=1; }
done

echo
if (( fail )); then echo "✗ docs lệch code"; exit 1; else echo "✓ docs khớp code"; fi
