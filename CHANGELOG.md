# Changelog

Mỗi bản phát hành là một GitHub Release `electron-b<số build>`, số build = số commit
(`git rev-list --count HEAD`). `release-electron.sh` lấy mục trên cùng của file này làm
release notes, nên **viết mục mới trước khi release**.

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
