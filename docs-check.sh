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
N=$(grep -rhoE 'FBMESS_[A-Z_]+' electron/ 2>/dev/null | sort -u | wc -l | tr -d ' ')
if [ "${N:-0}" -eq 0 ]; then
    say "HARNESS CHẾT: không tìm thấy env var nào trong electron/ — check này vô nghĩa"
    exit 1
fi
for v in $(grep -rhoE 'FBMESS_[A-Z_]+' electron/ | sort -u); do
    grep -rq "$v" README.md docs/ 2>/dev/null || { say "THIẾU: $v"; fail=1; }
done

echo "── script trong repo mà docs chưa nhắc ──"
for f in *.sh; do
    [[ "$f" == "docs-check.sh" ]] && continue
    grep -rq "$f" README.md docs/ 2>/dev/null || { say "THIẾU: $f"; fail=1; }
done

echo "── README nhắc env var không tồn tại trong code ──"
# Chỉ soi README.md ở chiều này, KHÔNG soi docs/ hay plans/: chúng là bản ghi thời điểm.
# docs/perf-process.md ghi số đo của bản Swift nên nhắc FBMESS_MODE là đúng với lúc đó —
# bắt chúng chỉ nhắc env var còn sống là bắt viết lại lịch sử. README thì phải luôn đúng
# hiện tại, vì đó là thứ người dùng đọc để chạy app.
for v in $(grep -rhoE 'FBMESS_[A-Z_]+' README.md 2>/dev/null | sort -u); do
    grep -rq "$v" electron/ *.sh || { say "README nhắc nhưng code không có: $v"; fail=1; }
done

echo
if (( fail )); then echo "✗ docs lệch code"; exit 1; else echo "✓ docs khớp code"; fi
