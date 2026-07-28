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

# Ad-hoc sign: đủ để UNUserNotificationCenter hoạt động khi chạy local.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo
echo "✓ $APP"
echo "  Chạy thử:  open \"$APP\""
echo "  Cài đặt:   cp -r \"$APP\" /Applications/"
