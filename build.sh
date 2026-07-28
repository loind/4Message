#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="FB Mess.app"
BIN="Messenger"
BUNDLE_ID="io.mobio.loind.fbmess"

# RELEASE_TUNE=default | fast
#   default  `-c release` — SwiftPM đã tự bật whole-module-optimization ở release.
#   fast     thêm LTO + bỏ các runtime check + dead-strip khi link.
#
# `-Ounchecked` bỏ precondition/bounds check. Selftest dùng `fatalError` nên vẫn chạy,
# nhưng LƯU Ý: mất luôn lưới an toàn overflow/bounds ở runtime.
RELEASE_TUNE=${RELEASE_TUNE:-default}
FLAGS=()
case "$RELEASE_TUNE" in
    default) ;;
    fast)
        FLAGS=(
            -Xswiftc -Ounchecked
            -Xswiftc -enforce-exclusivity=unchecked
            -Xswiftc -lto=llvm-thin
            -Xlinker -dead_strip
        )
        ;;
    *) echo "RELEASE_TUNE không hợp lệ: $RELEASE_TUNE (default|fast)" >&2; exit 1 ;;
esac

echo "tune=$RELEASE_TUNE ${FLAGS[*]:-}"
swift build -c release --product "$BIN" "${FLAGS[@]+"${FLAGS[@]}"}"
swift run -c release "$BIN" "${FLAGS[@]+"${FLAGS[@]}"}" --selftest

[[ -f Resources/AppIcon.icns ]] || ./make-icon.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$BIN" "$APP/Contents/MacOS/$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Nhúng thông tin build vào Info.plist. PHẢI làm trước codesign, sửa sau là signature vỡ.
# Lý do tồn tại: đã xảy ra chuyện một máy chạy bản cũ thiếu fix mà không cách nào biết.
PLIST="$APP/Contents/Info.plist"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_NO=$(git rev-list --count HEAD 2>/dev/null || echo 0)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then DIRTY=true; else DIRTY=false; fi

plist_set() {  # $1=key $2=type $3=value
    /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST" >/dev/null
}
plist_set CFBundleVersion string "$BUILD_NO"
plist_set FBMessGitCommit string "$COMMIT"
plist_set FBMessGitDirty bool "$DIRTY"
plist_set FBMessBuildDate string "$BUILD_DATE"

[[ "$DIRTY" == true ]] && echo "⚠ build từ working tree CHƯA COMMIT — bản này không tái tạo được từ git"

# Ad-hoc sign: đủ để UNUserNotificationCenter hoạt động khi chạy local.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo
echo "✓ $APP  —  build $BUILD_NO, commit $COMMIT$([[ "$DIRTY" == true ]] && echo " (dirty)")"
echo "  Chạy thử:  open \"$APP\""
echo "  Xem bản:   \"$APP/Contents/MacOS/$BIN\" --version"
echo "  Cài đặt:   cp -r \"$APP\" /Applications/"
