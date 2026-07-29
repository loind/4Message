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

## Service và ẩn chrome

`FBMESS_SERVICES=messenger,instagram,threads` (mặc định chỉ `messenger`). Mỗi service là
một origin riêng → cookie, IndexedDB, device E2EE riêng; phải đăng nhập từng service.

Ba cách đổi kênh:

| Cách | Ghi chú |
| --- | --- |
| **Rail dọc trong cửa sổ** | Hiện khi có >1 service. Tile màu thương hiệu, kênh đang xem sáng + viền trắng |
| Menu **Service** | Trên thanh menu, có dấu tick |
| ⌘1 / ⌘2 / ⌘3 | |

Rail hiện **số chưa đọc của từng kênh** — đó là lý do chính để có nó, thấy kênh khác có
tin mới mà không phải bấm qua. Với 1 service thì rail không dựng (chiếm chỗ mà không chọn
được gì).

Thu gọn rail: **Service → Ẩn cột kênh** (⌘0). Trạng thái lưu vào `UserDefaults` nên nhớ qua
lần chạy sau. Thu gọn rồi vẫn đổi kênh được bằng ⌘1/⌘2/⌘3 hoặc menu Service.

Thiết kế rail xem trước không cần chạy app:

```bash
swift tools/preview-rail.swift out.png
```

Nó render đúng control AppKit thật ra PNG offscreen — cần vì `screencapture` đòi quyền
Screen Recording. Lưu ý: đó là bản **dựng lại theo spec**, không phải ảnh chụp app đang
chạy, nên có thể lệch nếu sửa `main.swift` mà không sửa nó.

**Threads là FEED, không phải chat.** `threads.com/direct` và `/direct/inbox` đều redirect
về feed → web Threads không có surface DM (đã kiểm chứng). Giữ trong danh sách vì có thể
bạn vẫn muốn đọc feed, nhưng nó không có `hideRules` vì không có "chat" nào để tách khỏi
chrome.

Rule ẩn chrome nằm ở `Service.hideRules` (`Sources/Messenger/Services.swift`), riêng từng
service vì DOM hai site khác nhau hoàn toàn:

| Service | Ẩn | Selector |
| --- | --- | --- |
| Messenger | Thanh tab Home/Reels/Marketplace/Groups/Gaming | `[role="navigation"]:has(a[href^="/marketplace/"])` |
| Messenger | Ô nhập tìm kiếm | `input[aria-label="Search Facebook"]` |
| Messenger | Nút tròn kính lúp (wrapper của ô trên) | `*:has(> input[aria-label="Search Facebook"])` |
| Messenger | Nút X typeahead (UI chết sau khi ẩn search) | `[role="button"][aria-label="Exit typeahead"]` |
| Messenger | Nút Facebook menu (9 chấm) | `[role="button"][aria-label="Facebook menu"]` |
| Instagram | Home | `a[href="/"]` |
| Instagram | Reels | `a[href^="/reels/"]` |
| Instagram | Explore | `a[href^="/explore/"]` |

Giữ lại: danh sách hội thoại, `Search Messenger`, `New message`, `/direct/requests/`,
link profile (path chứa username nên không hardcode được), Notifications, Your profile.

**Ẩn CSS KHÔNG giảm memory** — DOM node vẫn tồn tại, React vẫn render và diff. Lợi ích thật
là chặn lỡ tay click vào Reels/Explore/Marketplace, những surface load rất nặng vào cùng
WebContent process.

### Bốn cái bẫy selector đã gặp

1. **`[role="navigation"]` trên facebook.com** — có 3 vùng: thanh tab, account controls, và
   **thread list**. Ẩn hết là mất danh sách hội thoại.
2. **`[role="navigation"]` trên instagram.com** — role đó là **chính panel danh sách hội
   thoại** (dòng chat 362×72), không phải rail bên trái. Rail nằm ngoài nó.
3. **`input[role="combobox"]`** — khớp cả ô `Search Messenger` của chính Messenger.
4. **`[aria-label*="Facebook" i]`** — khớp cả **một tin nhắn**, vì nội dung tin nhắn cũng
   được đưa vào `aria-label`.

Vì vậy: ưu tiên nhận theo `href` (độc lập ngôn ngữ và độc lập tài khoản); chỉ khi không có
href mới dùng **aria-label khớp chính xác** — khớp chính xác fail-safe, site đổi label thì
không ẩn được (vô hại) chứ không ẩn nhầm thứ đang cần.

### An toàn

- **Self-check** — 8 giây sau khi load, đếm element khớp từng rule và log cảnh báo cho rule
  nào khớp 0, kèm tên service.
- **Kill switch** — `FBMESS_KEEP_FB_CHROME=1` tắt toàn bộ, không cần rebuild. Cũng là cách
  chạy A/B để kiểm tra rule có phá layout chat không.

## Đo hiệu năng — so với Franz

```bash
./measure.sh "FB Mess"
./measure.sh Franz
```

```bash
./measure.sh "FB Mess"                       # chụp 1 thời điểm
./measure.sh "FB Mess" --watch               # theo dõi liên tục, ghi memory-track.csv
INTERVAL=300 ./measure.sh "FB Mess" --watch  # 5 phút/mẫu
```

Watch mode để trả lời câu snapshot không trả lời được: **memory phình lúc nào và process
nào phình**. Nó tách riêng app / GPU / Networking / WebContent, đếm số WebContent, và in
Δ so với mẫu đầu. Tự tra lại PID nếu app bị relaunch (và reset mốc Δ, vì process mới
không so được với process cũ).

Hai cột quan trọng:

- **RECLAIM** — trang OS lấy lại được **ngay** (clean/purgeable). **Không** tính phần cache
  mà WebKit tự purge khi nhận notification memory pressure — mà chính phần đó tạo ra mức
  giảm 42% trong `pressure-test.sh`. Nên **RECLAIM thấp không kết luận được là leak**: đo
  thực tế thấy một máy ở 130/1270 MB (10%) mà vẫn plateau hoàn toàn, còn máy khác
  351/585 MB (60%).
- **PEAK** — mức cao nhất từ lúc process sinh ra (chỉ ở snapshot mode).

Phân biệt cache với leak thì xem **đường có plateau không** (leak tăng đơn điệu, cache
phẳng ra), rồi xác nhận bằng `pressure-test.sh`.

Số lấy từ `/usr/bin/footprint --json`, đọc bằng `plutil` nên **chính xác tới byte** và
không cần python. Bản trước parse text của `vmmap`, trên 1 GB nó in `"1.4G"` nên độ phân
giải rơi xuống 100 MB — hai mẫu liên tiếp cùng đọc `1024.0 MB` từng che mất thay đổi thật.

Số liệu nghiêm túc để so phương án thì dùng `./bench.sh` với giao thức cố định —
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
