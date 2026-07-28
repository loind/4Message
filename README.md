# FB Mess

Client Messenger native cho macOS. Swift + AppKit host một `WKWebView` load `messenger.com`.
Thay thế Franz cho use case chat Facebook: nhẹ hơn, khởi động tức thì, không quảng cáo Pro.

Không reverse-engineer protocol của Facebook — dùng đúng web app chính thức, nên không
có rủi ro khoá tài khoản.

## Build

```bash
./build.sh          # build + selftest + đóng .app + ad-hoc sign
open "FB Mess.app"
```

Cài vào Applications:

```bash
cp -r "FB Mess.app" /Applications/
```

Chạy riêng phần kiểm tra logic:

```bash
swift run Messenger --selftest
```

## Dùng

| Thao tác | Kết quả |
| --- | --- |
| `⌘⇧M` | Hiện/ẩn cửa sổ (global, chạy được khi app đang ẩn) |
| Click icon menu bar | Hiện/ẩn cửa sổ |
| `⌘W` hoặc nút đóng | **Ẩn** cửa sổ, app vẫn chạy → lần sau mở tức thì |
| `⌘Q` | Thoát thật |
| `⌘R` | Tải lại |
| `⌘⇧R` | Xoá HTTP cache rồi tải lại (không chạm IndexedDB — nơi giữ khoá E2EE) |
| Badge trên dock | Số tin chưa đọc |
| Số cạnh icon menu bar | Số tin chưa đọc, ẩn khi bằng 0 |

Cả hai số đọc từ `document.title` của Messenger (`"(3) Chats · Messenger"`).

Đăng nhập một lần, session lưu trong `WKWebsiteDataStore` persistent nên sống qua restart.

## Đổi surface

Mặc định `https://www.facebook.com/messages/`. Override bằng `FBMESS_URL` (chỉ nhận
`https` và host trong `internalHosts`):

```bash
FBMESS_URL='https://www.messenger.com/' "FB Mess.app/Contents/MacOS/Messenger"
```

Chọn facebook.com vì Meta ship tính năng mới (Meta AI) vào đó trước, messenger.com bị bỏ
lại — dấu hiệu Meta chỉ còn đầu tư một surface. Đánh đổi: nặng hơn **~68 MB khi ẩn**
(655 vs 587 MB), CPU tương đương.

Đổi ngược không mất gì: hai origin cùng tồn tại trong `WKWebsiteDataStore`, lịch sử E2EE
của messenger.com nằm nguyên. Số liệu đầy đủ:
`docs/decisions/2026-07-28-facebook-com-surface.md`.

## Ẩn chrome Facebook

App tự ẩn 4 thứ trên surface facebook.com (`Sources/Messenger/Bridge.swift`, `hideChromeJS`):

| Ẩn | Selector |
| --- | --- |
| Thanh tab Home/Reels/Marketplace/Groups/Gaming | `[role="navigation"]:has(a[href^="/marketplace/"])` |
| Ô nhập tìm kiếm Facebook | `input[aria-label="Search Facebook"]` |
| Nút tròn kính lúp (wrapper của ô trên) | `*:has(> input[aria-label="Search Facebook"])` |
| Nút X của typeahead (UI chết sau khi ẩn search) | `[role="button"][aria-label="Exit typeahead"]` |
| Nút Facebook menu (9 chấm) | `[role="button"][aria-label="Facebook menu"]` |

Ẩn `<input>` thôi là chưa đủ — nút nhìn thấy được là `<label>` bọc ngoài (40×40,
`border-radius: 50px`) chứa icon kính lúp. **Bắt buộc dùng `> input`** trong `:has()`:
thiếu dấu `>` thì nó khớp mọi ancestor tới tận `<body>` và ẩn sạch trang.

Giữ lại: Notifications, Your profile, logo Facebook, và **toàn bộ Messenger** (thread list,
ô `Search Messenger`).

**Việc này KHÔNG giảm memory hay giảm load.** DOM node vẫn tồn tại, React vẫn render và
diff, request đã chạy vẫn chạy. Lợi ích thật là chặn lỡ tay click vào Reels/Marketplace —
những surface đó load rất nặng vào cùng WebContent process, mà memory thì ratchet lên rồi
không trả lại nhanh.

### Ba cái bẫy selector đã gặp

1. **`[role="navigation"]` trần** — trang này có **3** vùng navigation: thanh tab, account
   controls, và **thread list**. Ẩn hết là mất danh sách hội thoại.
2. **`input[role="combobox"]`** — khớp cả ô `Search Messenger` của chính Messenger.
3. **`[aria-label*="Facebook" i]`** — khớp cả **một tin nhắn**, vì nội dung tin nhắn cũng
   được đưa vào `aria-label`.

Vì vậy: thanh tab nhận theo `href` (độc lập ngôn ngữ), ba cái còn lại dùng **aria-label
khớp chính xác**. Khớp chính xác fail-safe — Facebook đổi label thì không ẩn được (vô hại),
chứ không ẩn nhầm thứ đang cần. Đánh đổi: phụ thuộc ngôn ngữ UI của Facebook.

### An toàn

- **Self-check** — 8 giây sau khi load, app đếm element khớp từng rule và log cảnh báo cho
  rule nào khớp 0, để CSS vỡ không âm thầm.
- **Kill switch** — `FBMESS_KEEP_FB_CHROME=1` tắt toàn bộ, không cần rebuild.

## Biết đang chạy bản nào

Từng xảy ra chuyện một máy chạy bản cũ thiếu fix mà không ai biết. Commit là thứ định
danh duy nhất đáng tin, nên `build.sh` nhúng nó vào `Info.plist` lúc đóng bundle.

Kiểm tra không cần mở GUI — dùng được cả trên máy khác:

```bash
"FB Mess.app/Contents/MacOS/Messenger" --version
```

```
FB Mess 0.1.0 (build 7)
commit   47c03c3
built    2026-07-28T13:18:36Z
surface  https://www.facebook.com/messages/
mode     baseline
macOS    26.5.2 (25F84)
```

Trong app: menu **Thông tin bản build…**, có nút Copy để dán vào báo lỗi. Cùng nội dung
đó cũng được ghi ra stderr ngay khi app khởi động — đọc log mà không biết bản nào sinh ra
nó thì vô dụng.

`CFBundleVersion` = `git rev-list --count HEAD`, nên số build tăng đơn điệu theo commit.

Nếu build khi working tree chưa commit, `build.sh` in cảnh báo và `--version` đánh dấu
**DIRTY** — bản đó không tái tạo được từ git.

## Đo hiệu năng — so với Franz

```bash
./measure.sh "FB Mess"
./measure.sh Franz
```

`measure.sh` chỉ xem nhanh. Số liệu nghiêm túc dùng `./bench.sh` với giao thức cố định —
xem `docs/perf-process.md`.

Số đo thật sau khi login (`phys_footprint`, chính là số Activity Monitor hiện):

| Trạng thái | Footprint | CPU |
| --- | --- | --- |
| Cửa sổ mở liên tục ~5 phút | ~990 MB | 8.5% |
| Cửa sổ ẩn | ~650 MB | 5.2% |
| Riêng shell Swift | 28 MB | 0.0% |

**Con số đó là cache, không phải memory app cần giữ.** Đã kiểm chứng bằng
`sudo ./pressure-test.sh` (simulate memory pressure, không cấp phát RAM thật):

| Mốc | page | worker | Tổng |
| --- | --- | --- | --- |
| Trước | 651 MB | 161 MB | 891 MB |
| Simulate WARN 30s | 625 MB | **bị kill** | 692 MB |
| Simulate CRITICAL 20s | 586 MB | — | 653 MB |
| Sau khi thả 20s | **450 MB** | respawn 10 MB | **516 MB** |

Giảm **42%** khi hệ thống cần RAM, và tiếp tục giảm cả sau khi đã thả pressure. Trong một
phiên khác nó tự tụt 918 → 610 MB sau ~10 phút idle mà không cần can thiệp gì.

Nghĩa là: **không leak, không cần fix.** `WebKit Malloc` (chiếm phần lớn) là bmalloc —
allocator có cache riêng, trả page về OS chậm rãi, và WebKit purge mạnh khi nhận
notification memory pressure. Máy còn RAM thì nó không có lý do co lại.

Hai điều **không** phải nguyên nhân, đã loại bằng đo:

- *Webview không được giải phóng?* Không. Luôn đúng 2 WebContent process (1 page +
  1 SharedWorker). Leak webview thì số process tích lũy.
- *Engine kém với Facebook?* Không. Phần tăng nằm ở DOM + render tree + ảnh decode;
  JS heap chỉ 20 MB. Memory-pressure handler của WebKit hoạt động đúng thiết kế.

Ẩn cửa sổ thì ngăn memory tăng thêm nhưng không trả lại ngay trong vòng 1 phút — phần trả
lại diễn ra chậm theo scavenger, hoặc tức thì khi có pressure.

Lưu ý phụ: dưới pressure thật, SharedWorker của Messenger bị kill rồi respawn — kênh
realtime khởi động lại nên notification có thể ngắt vài giây. Safari cũng vậy, không
kiểm soát được từ phía app.

96% memory là của web app Messenger — shell Swift chỉ 28 MB.

Đừng dùng `ps` RSS để đánh giá: nó báo ~2.5 GB vì gộp cả vùng code framework dùng chung
với Safari.

## Đã cắt (YAGNI — thêm khi thật cần)

- Multi-service (Zalo/Slack/Telegram) — chỉ Messenger
- Multi-account
- Tìm kiếm offline / lưu tin nhắn local — cần protocol access, approach này không có
- App icon riêng — hiện dùng icon generic
- Custom CSS ẩn story bar / suggested — selector của Messenger bị obfuscate, sẽ vỡ định kỳ

## Hạn chế đã biết

0. **E2EE: app là một thiết bị Messenger riêng biệt.** Hội thoại Messenger hiện mã hoá
   đầu cuối (URL dạng `/e2ee/t/...`). Nội dung tin nhắn chỉ giải mã được từ store cục bộ
   của từng thiết bị; server không giữ bản rõ. Hệ quả: app chỉ có lịch sử từ lúc bạn
   đăng nhập vào nó trở đi. Thread cũ không có tin mới sẽ hiện **preview trống hoặc cũ**,
   dù tên và avatar vẫn đúng (metadata đó lấy từ server). Đây là bản chất E2EE, không
   phải bug, và không sửa được từ phía app wrapper.

   Điều này cũng loại hẳn hướng viết native protocol client: phải tự implement giao thức
   E2EE của Meta, khó hơn nhiều lần so với giao thức plaintext cũ.

1. **Autofill mật khẩu từ Keychain không hoạt động** trong `WKWebView`. Lần đầu phải nhập
   hoặc paste tay.
2. **Notification phụ thuộc `window.Notification`.** `WKWebView` không có Web Notifications
   API nên app shim lại API này (`Sources/Messenger/Bridge.swift`). Nếu Messenger đổi sang
   Service Worker Push thì shim không bắt được — lúc đó notification sẽ im lặng. Đây là
   điểm dễ vỡ nhất của app.
3. **RAM không thể xuống ~50 MB.** Muốn vậy phải viết native protocol client, đánh đổi bằng
   rủi ro khoá tài khoản. Đã cân nhắc và loại.
4. **Notification khi app ẩn lâu chưa được xác minh.** Mặc định (`baseline`) giữ assertion
   chặn App Nap để kết nối realtime không bị throttle. Có 3 mode khác để thử nghiệm
   (`FBMESS_MODE=throttle|suspend|block`) — xem `docs/perf-process.md`. Mode `throttle`
   tốn ít CPU hơn rõ rệt nhưng **chưa chứng minh được là không làm chết kết nối**, nên
   chưa đặt làm mặc định.
5. `⌘⇧M` có thể trùng hotkey app khác. Sửa `kVK_ANSI_M` trong `main.swift:applicationDidFinishLaunching`.
6. Voice/video call chưa kiểm tra thực tế (đã cấp quyền camera/mic trong `Info.plist` và
   `requestMediaCapturePermissionFor`).

## Cấu trúc

```
Sources/Messenger/
  main.swift     AppDelegate, window, menu, notification bridge, navigation, recovery
  Bridge.swift   JS inject: shim window.Notification → native UNUserNotificationCenter
  Hotkey.swift   Global hotkey qua Carbon RegisterEventHotKey (không cần quyền Accessibility)
Resources/Info.plist
build.sh         build + selftest + bundle + ad-hoc sign
measure.sh       đo RSS/CPU gồm cả helper process
```
