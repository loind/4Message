# Changelog

Mỗi bản phát hành là một GitHub Release `electron-b<số build>`, số build = số commit
(`git rev-list --count HEAD`). `release-electron.sh` lấy mục trên cùng của file này làm
release notes, nên **viết mục mới trước khi release**.

## b75 — 2026-10-10

### Thêm

- **Chuột phải vào ảnh → Copy ảnh / Lưu ảnh…** Hoạt động ở cả bốn kênh. Copy đưa bitmap vào
  clipboard, ⌘V dán được sang Notes/Preview/Slack; Lưu mở Save panel, mặc định `~/Downloads`
  với tên file đã chuẩn hoá theo mime. Chuột phải chỗ không phải ảnh thì app không chen vào,
  trang tự xử như cũ.

  Electron **không** tự dựng context menu như Chrome — nó chỉ phát event rồi để app quyết,
  nên trước đây chuột phải vào ảnh trong chat không ra gì.

  Ảnh trong Messenger/Instagram/Threads thường bị element khác phủ lên, làm Chromium trả
  `hasImageContents = false`. App dò `elementsFromPoint` tìm `<img>`, và lúc copy thì tạm
  tắt `pointer-events` của lớp phủ để hit-test của `copyImageAt` chạm được tới ảnh. Hai
  đường khác đều đã đo và đều chết: `nativeImage` không decode webp/gif (Meta serve webp là
  chính), còn vẽ ra canvas thì `toDataURL` ném `SecurityError` vì ảnh CDN không có CORS.
  Số đo đầy đủ: `plans/2026-08-24-copy-image/design.md`.

- **Probe mới `--probe-image`** — 15 assert cho cơ chế menu ảnh, gồm cả ca ảnh bị lớp phủ
  che: copy phải ra bitmap đúng kích thước trong clipboard, và `pointer-events` phải được
  trả lại. Nằm ngoài ràng buộc thứ tự của ba probe kia vì không đụng `prefs.json`.

### Sửa

- **`--probe-image` không còn FAIL oan trên máy chưa đăng nhập.** Khối assert chạy trên
  view riêng ghim vào trang tĩnh thay vì mượn view của kênh. Máy chưa login thì Messenger
  nhảy redirect liên tục (`login.php` → `index.php` → …); mỗi lần điều hướng là một renderer
  mới, nên `<img>` vừa chèn biến mất và `sendInputEvent` bắn vào widget đã chết — không
  event `context-menu` nào tới nơi và **11 assert FAIL cùng lúc**, đọc y hệt một lỗi tính
  năng thật.

  Đo 2026-10-10 trên máy chưa đăng nhập: trước 11 FAIL, sau 15/15 PASS, không đổi một dòng
  code tính năng nào. Positive control đã chạy — phá `SAVABLE_PROTOCOLS` và phá luật
  `minSide` thì `selftest.js` fail đúng chỗ, nên bộ kiểm không phải loại "báo sạch vì không
  kiểm gì".

  View probe dựng qua `makeServiceView` chứ không `new WebContentsView` tay: handler
  `wc.on('context-menu')` — thứ đang được kiểm — nằm trong đó.

### Ghi chú

- `--probe-image` chạy trên `userData` **thật** (cần session đăng nhập mới đo được ảnh chat
  thật), nên **thoát app trước khi chạy**. Nó cướp focus và **ghi đè clipboard**.

## b74 — 2026-08-08

### Sửa

- **Badge không còn biến mất khi đang có tin chưa đọc.** b73 trừ số thông báo Facebook khỏi
  số trong title, nhưng title **chỉ đếm tin nhắn** — phép trừ đó cho kết quả âm và xoá sạch
  badge. Ai có nhiều thông báo chưa xem thì gần như không bao giờ thấy badge tin nhắn nữa.

  Đo 2026-08-08: title `"(1) Messenger | Facebook"` trong khi chuông mang **6** thông báo và
  thread list có đúng **1** dòng `"Unread message"`. Nếu title gộp thông báo thì nó đã phải
  là `(7)`. Kết luận của b73 dựa trên ba mẫu đo, trong đó lần title `(1)` tình cờ trùng lúc
  chuông có số — trùng hợp bị đọc thành nhân quả.

  Nay bỏ hẳn phép trừ, không còn đọc DOM nút chuông nữa.

### Giữ nguyên từ b73

- Badge vẫn không chớp tắt: title flash `"Ai đó messaged you"` vẫn được hiểu là "chưa biết"
  thay vì "đã đọc hết". Phần này đo bằng log title thật và vẫn đúng.

## b73 — 2026-08-08

### Sửa

- **Badge không còn đếm thông báo Facebook.** Số trên icon Dock và menu bar chỉ tính tin
  nhắn Messenger. Trước đây một thông báo fanpage (like, comment, bài mới) cũng đẩy badge
  lên như thể có tin nhắn mới.

  Nguyên nhân: app đọc số chưa đọc từ `document.title`, mà `(N)` trong title của
  `facebook.com` là **tổng badge toàn site** — tin nhắn cộng thông báo. Chỗ đọc badge được
  viết cho title của `messenger.com` (`"(3) Chats · Messenger"`) và không được soát lại khi
  surface đổi sang `facebook.com/messages` hồi 2026-07-28. Nay trừ đi số trên chuông thông
  báo, đọc từ `[aria-label="Notifications"]`.

- **Badge không còn chớp tắt.** Facebook nhấp nháy title mỗi 2 giây sang dạng
  `"Ai đó messaged you"`, không mang số — app đọc thành 0 rồi xoá badge, 2 giây sau lại
  hiện. Nay dạng title đó được hiểu là "chưa biết" và giữ nguyên badge; chỉ title nghỉ
  (`"Messenger | Facebook"`) mới xoá.

### Ghi chú

- Không đọc được nút chuông thì **không trừ** — thà badge cao hơn thực còn hơn nuốt mất tin
  nhắn.
- Cả hai luật đo trên tài khoản thật ngày 2026-08-07; `electron/selftest.js` kiểm bằng
  chính các chuỗi title lấy từ log đo, không phải chuỗi bịa cho khớp hàm.
- Luật gắn với **surface** `facebook.com`, đánh dấu bằng `unreadRule: 'facebook'` trong
  `electron/services.js`. Đổi kênh Messenger về `messenger.com` thì bỏ cờ đó đi.
