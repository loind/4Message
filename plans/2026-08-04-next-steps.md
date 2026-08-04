# Đầu việc treo — chốt ngày 2026-08-04

Project tạm dừng ở commit `6bfb07c`, app đóng gói dùng được với 4 kênh
(`messenger+instagram+threads+zalo`). Ghi lại để lần sau khỏi dò lại.

## 1. Badge unread của Zalo — CHƯA kiểm chứng

Badge trên rail đọc số chưa đọc từ `document.title` (`unreadFromTitle`), khớp mẫu
`(3) …`. Đã đo được title của Zalo **khi chưa login**:

| Trạng thái | `document.title` |
| --- | --- |
| Vừa mở `chat.zalo.me` | `Zalo - Đăng nhập Zalo` |
| Sau redirect sang `id.zalo.me` | `Đăng nhập tài khoản Zalo` |

Chưa biết title **sau khi login** có mang số chưa đọc hay không — cần một tài khoản đã
quét QR. Cách kiểm: chạy `FBMESS_SERVICES=zalo` rồi `--probe` (in url + title + unread cho
từng kênh, xem `electron/main.js`).

Nếu Zalo **không** ghi số vào title thì tile Zalo sẽ không bao giờ có badge dù có tin mới,
và phải đọc số bằng cách soi DOM riêng cho Zalo. Việc đó vượt xa "khai báo thêm một
service" — nó là service đầu tiên cần đường lấy unread riêng, tức `unreadFromTitle` phải
thành một hàm cắm được theo service.

## 2. Multi-account (login 2 tài khoản cùng lúc) — mới dừng ở khảo sát

Yêu cầu: login 2 account Facebook/Instagram/Threads cùng lúc. Chưa thiết kế, chưa chốt
gì. Những gì đã khảo sát:

| Điểm | Trạng thái hiện tại | Ý nghĩa cho multi-account |
| --- | --- | --- |
| Session bản Electron | **Một** partition `persist:fbmess` dùng chung cho cả 4 kênh (`electron/main.js:85`) | Phải thành một partition mỗi account. Đổi tên partition là **mất login đang có** → account thứ nhất bắt buộc giữ đúng tên `persist:fbmess` |
| Session bản Swift | `WKWebsiteDataStore.default()` (`main.swift:777`) | Cần `WKWebsiteDataStore(forIdentifier:)`, một identifier mỗi account |
| Cấu trúc kênh | `runtimes[]` = `{service, view, unread}`, rail và ⌘N đều theo **index** | Thêm "kênh thứ 5 = Facebook account 2" không phá gì — kiến trúc đã sẵn |
| Handler quyền | Đăng ký cho **đúng một** partition (`electron/main.js:235`) | Phải đăng ký cho từng partition, nếu không thì account 2 mất notification và mic/camera |
| Glyph rail | Tra theo `service.id` (`electron/rail.html`) | Hai kênh cùng service sẽ trùng glyph → cần cách phân biệt trên tile (nhãn account?) |

Câu chưa trả lời: cú pháp khai báo account trong `FBMESS_SERVICES` là gì, kênh nào cần 2
account, và tile trùng glyph thì phân biệt bằng gì.

## 3. Việc nhỏ

- `measure.sh:55` / `freeze-sample.sh:52` truyền biến rỗng vào `footprint --json` thì sinh
  ra file tên `.json` ở gốc repo — đúng cái file rác vừa xoá ở `6bfb07c`. Chưa sửa.
