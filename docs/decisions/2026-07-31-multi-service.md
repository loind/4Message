# Multi-service: Messenger + Instagram + Threads trong một app

**Ngày:** 2026-07-31
**Quyết định:** một app, một cửa sổ, rail chọn kênh. Mỗi service một `WKWebView` riêng.

## Điểm căng thẳng

Multi-service chính là thứ đã làm Franz nặng: Franz = N service × Electron. Nếu giữ tất cả
resident thì ta tái tạo đúng vấn đề đó, chỉ nhỏ hơn về hệ số — Messenger một mình đã
600 MB–1.2 GB, ba service có thể 2–3 GB.

Nên topology không phải chuyện thẩm mỹ mà là chuyện memory.

## Ba service, và vì sao Threads có mặt

| Service | Surface | Ghi chú |
| --- | --- | --- |
| Messenger | `facebook.com/messages` | Xem `2026-07-28-facebook-com-surface.md` |
| Instagram | `instagram.com/direct` | |
| Threads | `threads.com/messages` | **Không phải `/direct`** |

Threads từng bị tôi **loại khỏi danh sách** với lý do "web Threads không có DM" — dựa trên
việc `/direct` và `/direct/inbox` redirect về feed. Kết luận đó sai: DM của Threads ở
`/messages/`, tôi suy diễn đường dẫn theo Instagram thay vì soi DOM.

Và việc loại nó là **thu hẹp scope theo phán đoán của tôi**, không phải quyết định của
user — user đã yêu cầu Threads ngay từ đầu.

## Mỗi service là một origin riêng

Không chia sẻ gì: cookie, IndexedDB, device E2EE đều riêng. Hệ quả thực tế:

- **Phải đăng nhập từng service.** Session của cái này không dùng được cho cái kia.
- **Mỗi service là một thiết bị E2EE mới**, nên lịch sử tin nhắn cũ không có sẵn — xem mục
  E2EE trong README.
- Đổi surface của một service không ảnh hưởng service khác.

## Link policy tách theo service

`isSurface(_:of:)` quyết định link user **click** có ở lại trong app không, và nó phải
riêng từng service — nếu dùng chung thì link Instagram mở trong cửa sổ Messenger.

Khác với `internalHosts`, thứ chỉ trả lời "host nào được phép **load**" và buộc phải rộng
hơn vì luồng login redirect qua nhiều domain.

Ràng buộc path phải gắn với **host**, không phải service: `facebook.com` chỉ có `/messages`
là chat còn lại là feed, nhưng `messenger.com` và `m.me` thì cả domain đều là chat. Đặt
prefix ở cấp service làm `messenger.com/t/<id>` bị từ chối — selftest bắt được.

## Topology: `tabs` là mặc định, `windows` chưa đo

`FBMESS_TOPOLOGY=tabs|windows`. Cả hai đã implement để **đo rồi mới chọn**, nhưng phép đo
chưa chạy.

Bằng chứng có trước khi đo, gợi ý hai phương án có thể tương đương: macOS coi cửa sổ **bị
che hoàn toàn** là không visible và WebKit dừng render — log có
`window occluded 1 → viewIsBecomingInvisible`. Nên `windows` xếp chồng sẽ hành xử gần giống
`tabs`; khác biệt chỉ lộ khi các cửa sổ **cùng nhìn thấy** cạnh nhau.

Nếu ra null result thì chọn theo độ phức tạp code, và `tabs` thắng vì `windows` cần quản lý
N cửa sổ, N title, N frame autosave.

### Một hệ quả của `tabs` đã đo được

Ở `tabs`, chỉ webview của service đang active được attach vào view hierarchy; các cái còn
lại **detach** — đó là điều kiện để `WKPreferences.inactiveSchedulingPolicy` có hiệu lực.

Nhưng detach cũng làm **JS bị throttle**: rule ẩn chrome của Threads báo khớp **0** khi nó
là service nền, và khớp **đủ 5** khi là service duy nhất. Nghĩa là **service nền có thể
nhận notification trễ**.

Đây chính là đánh đổi tabs-vs-windows, giờ có cơ chế cụ thể thay vì chỉ giả thuyết. Phép đo
còn treo nên cần đo cả **notification latency**, không chỉ memory.

## Rail chọn kênh

Menu bar không đủ dễ thấy — user báo "không thấy việc chọn insta và thread". Nguyên nhân
thật là bug thứ tự khởi tạo (`buildMenu()` chạy trước `buildUI()` nên `runtimes` còn rỗng),
nhưng kể cả khi chạy đúng thì item bị chôn trong app menu.

Rail dọc trong cửa sổ, tile màu thương hiệu, **hiện số chưa đọc từng kênh** — đó là lý do
chính để có nó thay vì chỉ menu: thấy kênh khác có tin mới mà không phải bấm qua.

Thu gọn được (⌘0), trạng thái lưu `UserDefaults`. Với 1 service thì rail không dựng.

Các bẫy layout và selector gặp khi làm phần này: `docs/ui-discipline.md`.

## Còn treo

- Bench `tabs` vs `windows` (memory + notification latency).
- Rule ẩn chrome cho Instagram/Threads mới nhắm rail điều hướng; chưa soi các panel khác.
- Instagram/Threads chưa có badge unread riêng đáng tin — số hiện tại đọc từ
  `document.title`, mà title của hai site đó không chắc phản ánh số DM chưa đọc.
