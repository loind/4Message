# Dùng `facebook.com/messages` làm surface mặc định

**Ngày:** 2026-07-28
**Quyết định:** đổi mặc định từ `https://www.messenger.com/` sang
`https://www.facebook.com/messages/`.

**Ghi chú:** quyết định này đảo ngược kết luận tạm thời trước đó trong cùng ngày (giữ
messenger.com vì nhẹ hơn 68 MB). Lý do đảo ngược nằm ở mục "Điều làm đổi quyết định".

## Bối cảnh

Ban đầu đề xuất chuyển sang facebook.com dựa trên phỏng đoán messenger.com đã dừng phát
triển vì Meta khai tử app Messenger desktop. **Phỏng đoán đó sai** — Meta khai tử app
*native*, còn `messenger.com` là web app, sản phẩm khác, vẫn hoạt động đầy đủ.

## Đã xác minh bằng đo

`facebook.com/messages` là client Messenger đầy đủ (route `/messages/e2ee/t/<id>`), không
phải panel rút gọn, và không redirect về messenger.com.

Bench cùng giao thức (`LOAD=120s SOAK=180s`), 2 run mỗi surface, chạy **xen kẽ**
`fb → msg → fb → msg` để nhiễu do trôi thời gian phân bổ đều:

| Surface | T1 hiện (MB) | T2 ẩn (MB) | CPU T2 | Số process |
| --- | --- | --- | --- | --- |
| `facebook.com` | 665.9 (spread 34.5) | 654.9 (spread 17.2) | 5.3% | 4 |
| `messenger.com` | 622.8 (spread 0.8) | **587.2** (spread 3.1) | 5.55% | 5 |

**messenger.com nhẹ hơn ~68 MB khi ẩn, ~43 MB khi hiện.** CPU tương đương. Chênh lệch nằm
ngoài spread nội bộ nên là thật.

Nghịch lý đáng ghi: facebook.com có **ít process hơn** (4 vs 5 — không spawn SharedWorker
riêng) nhưng **tổng nặng hơn**, vì page process gánh cả shell Facebook. Một phép đo n=1
lúc đầu đã cho kết luận ngược (tưởng facebook.com nhẹ hơn ~120 MB) chỉ vì thấy thiếu
SharedWorker và mốc đo lệch giao thức. **Đếm process không thay cho đo footprint tổng.**

## Điều làm đổi quyết định

Quan sát trực tiếp: **Meta AI gọi được trên facebook.com, không gọi được trên
messenger.com** — cùng một account, nên đã loại yếu tố vùng miền.

Đây là phân kỳ tính năng có thật, khác hẳn phỏng đoán ban đầu, và là chỉ dấu sớm đáng tin
của việc một surface bị bỏ rơi: Meta ship tính năng mới vào chỗ họ còn đầu tư.

Probe DOM trong repo **không xác minh được** điều này, và đó là giới hạn của công cụ chứ
không phải bằng chứng phản bác:

- `metaAiText` false ở cả hai — Meta AI có thể chỉ xuất hiện trong luồng compose.
- `metaAiNodes` phiên bản đầu dùng `[aria-label*="AI" i]`, khớp cả "M**ai**l", "M**ai**n",
  "Av**ai**lable" → số liệu rác. Đã siết còn `[aria-label*="Meta AI" i]`.
- `unsupported` từng báo true ở cả hai vì regex chứa từ "trình duyệt" trần, khớp mọi thông
  báo cookie. Đã siết thành "cập nhật trình duyệt".

## Vì sao 68 MB không thắng được

1. **~11%**, không phải bội số. Và pressure test cho thấy phần lớn memory đó là cache OS
   lấy lại được (891 → 516 MB dưới pressure).
2. **Đổi ngược gần như miễn phí.** Hai origin cùng tồn tại trong `WKWebsiteDataStore`;
   chuyển sang facebook.com **không xoá gì** ở origin messenger.com. Lịch sử E2EE bên đó
   nằm nguyên, quay lại chỉ cần đổi `FBMESS_URL`.
3. **Chi phí đổi đang ở mức thấp nhất.** Origin messenger.com mới tích luỹ lịch sử E2EE
   khoảng một ngày. Càng để lâu, nếu sau này buộc phải đổi thì càng mất nhiều.

## Chi phí đã chấp nhận

| Chi phí | Mức độ |
| --- | --- |
| Nặng hơn ~68 MB khi ẩn | Chấp nhận — ~11%, và là cache reclaim được |
| Phải đăng nhập riêng cho `facebook.com` | Một lần, đã làm |
| Thiết bị E2EE mới → preview tin cũ trống | Tự tích luỹ lại theo thời gian |
| Có banner + rail điều hướng của Facebook | Chưa xử lý — xem mục dưới |

## Về việc ẩn chrome Facebook

**Chưa làm.** Nếu về sau thấy vướng thì dùng `[role="banner"]` / `[role="navigation"]`,
**không** dùng class hash.

Selector kiểu `#mount_0_0_wK > … > div.x9f619.x1n2onr6.x1ja2u2z…` không dùng được:

- `mount_0_0_wK` — hậu tố là token random **mỗi lần load trang**.
- `x9f619`, `x1ja2u2z`… — class atomic do Stylex sinh lúc build, đổi theo mỗi deploy.

Quan trọng hơn: **ẩn DOM không giảm memory.** Node vẫn tồn tại, React vẫn render và diff,
network và timer vẫn chạy. Lợi ích chỉ là thẩm mỹ. Còn reparent node bằng DOM surgery thì
phá React — modal, media viewer, emoji picker, dropdown đều mount qua portal ở nhánh khác.

Nếu làm, kèm self-check đếm số element khớp; bằng 0 thì cảnh báo, để CSS vỡ không âm thầm.

## Cách quay lại

```bash
FBMESS_URL='https://www.messenger.com/' "FB Mess.app/Contents/MacOS/Messenger"
```

`FBMESS_URL` chỉ nhận `https` và host trong `internalHosts`, có test trong `--selftest`.
