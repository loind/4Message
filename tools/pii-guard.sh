#!/usr/bin/env bash
# Chặn PII và secret lọt vào repo.
#
#   tools/pii-guard.sh --staged     # chỉ dòng THÊM trong staged diff (pre-commit hook)
#   tools/pii-guard.sh --tree       # toàn bộ file đang tracked (gate trước khi publish)
#   tools/pii-guard.sh --history    # mọi commit — chậm, dùng khi audit
#
# Vì sao tồn tại: repo này từng public kèm tên thật của ba người, username Instagram và
# thread ID E2EE — nằm trong file .log commit rồi xoá. Dọn tốn force-push, xoá tag, rồi
# xoá và tạo lại repo. Chặn lúc commit rẻ hơn nhiều lần.
#
# Vì sao có SELF-TEST: harness kiểm trong repo này đã hỏng 6 lần và LẦN NÀO CŨNG báo
# "sạch" — grep ăn stdin, dấu -- thừa, zsh không word-split, fetch làm bẩn lại, exit code
# lấy của head. Guard PII im lặng còn tệ hơn không có guard vì nó tạo niềm tin sai. Script
# tự kiểm từng mẫu trên fixture trước; mẫu nào không khớp fixture của chính nó thì DỪNG.
#
# MỌI FIXTURE PHẢI LÀ DỮ LIỆU GIẢ. Bản nháp đầu tiên của file này dùng tên người thật,
# thread ID thật và username thật làm fixture — tức là bộ dò PII tự nhét PII vào repo.
set -uo pipefail
cd "$(dirname "$0")/.."

MODE="${1:---staged}"
ALLOW=tools/pii-allow.txt
# Hai file này chứa fixture và regex theo thiết kế nên luôn khớp chính mình.
SELF="tools/pii-guard.sh tools/pii-allow.txt"

# Dạng: tên <TAB> regex <TAB> fixture.
# KHÔNG dùng PATTERNS=$(cat <<'X' ...): bash 3.2 vẫn diễn giải nháy trong thân heredoc khi
# nó nằm trong command substitution, và một dòng có số nháy lẻ là gãy parser cả file.
patterns() {
cat <<'PAT'
cookie-meta	(c_user=|xs=[A-Za-z0-9%]|datr=[A-Za-z0-9]|sessionid=[A-Za-z0-9]|ds_user_id=|csrftoken=)	c_user=100000000000000
token-key	(ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|sk-[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10}|AIza[0-9A-Za-z_-]{30})	ghp_aaaaaaaaaaaaaaaaaaaaaaaa
private-key	-----BEGIN [A-Z ]*PRIVATE KEY	-----BEGIN RSA PRIVATE KEY-----
jwt	eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}	eyJhbGciOiJIUzI1NiIsInR5.eyJzdWIiOiIwMDAwMDAwMDAw
thread-id	/(e2ee/)?t/[0-9]{12,}	/e2ee/t/1234567890123456
email	[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.(com|net|org|io|vn|me)	fixture@example.com
home-path	/Users/[a-z0-9._-]+/	/Users/testuser/Downloads
probe-dump	\[fbmess\] .*(state=\{|page=https)	[fbmess] [x] page=https://example.com/
aria-dump	(LABELQ[^"]{2,}".*){3,}	LABELQaaa",LABELQbbb",LABELQccc"
PAT
}

red() { printf '\033[31m%s\033[0m\n' "$1"; }
say() { printf '  %s\n' "$1"; }

# `"label":"` viết thẳng vào heredoc thì regex và fixture lệch số nháy, nên dùng placeholder
# LABELQ rồi thay lúc chạy. Đây là cách duy nhất giữ được mẫu mà không gãy parser.
expand() { printf '%s' "$1" | sed 's/LABELQ/"label":"/g'; }

selftest() {
    local bad=0 name re fx
    while IFS=$'\t' read -r name re fx; do
        [ -z "${name:-}" ] && continue
        re=$(expand "$re"); fx=$(expand "$fx")
        if ! printf '%s\n' "$fx" | grep -qE -e "$re"; then
            red "SELF-TEST FAIL: mẫu '$name' không khớp fixture của chính nó"
            say "regex  : $re"
            say "fixture: $fx"
            bad=1
        fi
    done < <(patterns)
    if [ "$bad" -ne 0 ]; then
        red "GUARD ĐÃ CHẾT — không quét gì cả. Sửa regex trước đã."
        exit 2
    fi
}

allowed() {
    [ -f "$ALLOW" ] || return 1
    local a
    while read -r a; do
        [ -z "$a" ] && continue
        case "$a" in \#*) continue ;; esac
        printf '%s\n' "$1" | grep -qE -e "$a" && return 0
    done < "$ALLOW"
    return 1
}

# $1 nội dung, $2 nhãn nguồn. Trả 1 nếu tìm thấy.
scan_text() {
    local content="$1" src="$2" found=0 name re fx line
    while IFS=$'\t' read -r name re fx; do
        [ -z "${name:-}" ] && continue
        re=$(expand "$re")
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            allowed "$line" && continue
            [ "$found" -eq 0 ] && { red "PII/secret trong $src:"; found=1; }
            # Cắt ngắn: đủ để tìm ra chỗ, không in trọn nội dung nhạy cảm ra terminal.
            say "[$name] $(printf '%s' "$line" | cut -c1-110)"
        done <<< "$(printf '%s\n' "$content" | grep -aE -e "$re" | head -5)"
    done < <(patterns)
    return $found
}

selftest
bad=0

case "$MODE" in
  --staged)
    # Quét TỪNG FILE chứ không quét cả blob diff: cần bỏ qua chính guard (nó chứa fixture
    # theo thiết kế), và báo cáo nêu được tên file thì mới sửa nhanh được.
    # Chỉ dòng THÊM: nội dung cũ trong file không bị flag lại mỗi lần sửa.
    for f in $(git diff --cached --name-only --diff-filter=ACMR); do
        case " $SELF " in *" $f "*) continue ;; esac
        added=$(git diff --cached -U0 --no-color -- "$f" | grep -aE '^\+' | grep -av '^+++')
        [ -n "$added" ] && { scan_text "$added" "$f" || bad=1; }
    done
    # File .log/.json rác từng lọt vào đúng kiểu này — gitignore chặn, git add -f vượt qua.
    for f in $(git diff --cached --name-only --diff-filter=A); do
        case "$f" in
          *.log|.json|*/.json)
            red "file nghi là output probe: $f"
            say "gitignore đã chặn — chỉ vào được bằng git add -f"
            bad=1 ;;
        esac
    done
    ;;
  --tree)
    for f in $(git ls-files); do
        [ -f "$f" ] || continue
        case " $SELF " in *" $f "*) continue ;; esac
        grep -Iq . "$f" 2>/dev/null || continue          # bỏ binary
        scan_text "$(cat "$f")" "$f" || bad=1
    done
    ;;
  --history)
    ALL=$(git rev-list --all)
    while IFS=$'\t' read -r name re fx; do
        [ -z "${name:-}" ] && continue
        re=$(expand "$re")
        hits=$(printf '%s\n' "$ALL" | xargs git grep -I -l -E -e "$re" 2>/dev/null \
               | sed 's/^[0-9a-f]*://' | sort -u | grep -vE "^(tools/pii-)" | head -5)
        [ -n "$hits" ] && {
            red "[$name] còn trong history:"; printf '%s\n' "$hits" | sed 's/^/    /'; bad=1; }
    done < <(patterns)
    ;;
  *) echo "dùng: $0 [--staged|--tree|--history]"; exit 64 ;;
esac

if [ "$bad" -ne 0 ]; then
    echo
    red "CHẶN. Bỏ nội dung trên ra khỏi commit."
    say "False positive thật thì thêm regex vào $ALLOW — mỗi dòng ở đó là một lỗ thủng."
    say "Bỏ qua một lần (KHÔNG khuyến khích): git commit --no-verify"
    exit 1
fi
echo "✓ pii-guard: sạch ($MODE, $(patterns | grep -c . ) mẫu đã self-test)"
