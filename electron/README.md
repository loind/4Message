# FB Mess (Electron)

Bản dùng engine Blink của cùng app. Cùng UX với bản Swift: rail chọn kênh, ẩn chrome
không liên quan tới chat, link ngoài surface mở browser, tray resident, ⌘⇧M bật/tắt cửa sổ,
badge unread ở Dock + menu bar.

Lý do tồn tại: WKWebView bùng 60–100% CPU theo đợt làm nội dung đóng băng. Đo cùng trang
Messenger, Blink trung bình 0.58% qua 14 giờ. Chi tiết: `plans/2026-08-03-engine-swap/`.

## Build

```bash
./build-electron.sh            # → "FB Mess Electron.app" ở gốc repo (arm64)
./build-electron.sh --run
FBMESS_ARCH=universal ./build-electron.sh   # nếu cần chạy trên Intel
```

`selftest.js` là cổng build — check logic surface/unread thuần, không cần GUI hay mạng.

## Kiểm tra khi không có màn hình

```bash
"./FB Mess Electron.app/Contents/MacOS/FB Mess Electron" --probe
```

In ra: số tile của rail, URL + title + trạng thái login của từng service, và hai case
link policy (link ngoài phải ra browser, link surface phải giữ trong app). Cần vì máy build
không có GUI session — `screencapture` ở đó chỉ ra desktop trống.

## Env

| Biến | Tác dụng |
| --- | --- |
| `FBMESS_SERVICES=messenger,instagram` | Chọn và sắp thứ tự kênh |
| `FBMESS_KEEP_FB_CHROME=1` | Không inject CSS ẩn chrome (để so sánh khi debug) |

## Session tách riêng với bản Swift

Store ở `~/Library/Application Support/FB Mess Electron/`, không phải `~/Library/WebKit/`.
Cookie KHÔNG chuyển sang được → phải login lại cả ba kênh. Mỗi lần login là một device
E2EE mới, nên hội thoại mã hoá đầu-cuối sẽ không có lịch sử cũ ở app này.

## Khác biệt so với bản Swift

| Việc | Swift | Electron |
| --- | --- | --- |
| Web Notification | shim JS → `UNUserNotificationCenter` | Blink hiện native, chỉ cần cấp quyền |
| Chặn link | `navigationType == .linkActivated` | click capture trong preload (`will-navigate` không phân biệt được click với redirect của luồng login) |
| Thu gọn rail | có | chưa có |
| Hotkey | Carbon `RegisterEventHotKey` | `globalShortcut` |
