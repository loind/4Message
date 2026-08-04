# Chốt engine: WKWebView hay Blink

Tiếp `plans/2026-08-03-engine-swap/brainstorm.md` — lúc đó là câu hỏi "có thay engine được
không". Giờ cả hai bản đều chạy được với 4 kênh, câu hỏi thành: **giữ bản nào**.

Đây là quyết định gate — hai chủ đề còn lại (phân phối/auto-update, unread cắm được theo
service) phải làm gấp đôi nếu vẫn duy trì song song.

## Vấn đề

Đang bảo trì hai bản của cùng một app:

| | Swift (WKWebView) | Electron (Blink) |
| --- | --- | --- |
| Dòng code | 1681 (`Sources/Messenger/`) | 646 (`electron/`) |
| Bundle | 1.2 MB | 276 MB (zip 129 MB) |
| Kênh | 4 | 4 |
| Login | đã login trên MacBook, có lịch sử E2EE | chưa login |

`electron/services.js` là **mirror tay** của `Sources/Messenger/Services.swift`. Commit
`02a7556` (Threads mở feed + thêm Zalo) đã phải sửa cả hai file — chi phí song song không
còn là giả thuyết, nó đã xảy ra một lần rồi.

Lệch đã có: thu gọn rail (⌘0) có ở Swift, thiếu ở Electron.

## Bằng chứng

### Freeze — vững, không có confound

Đây là lý do gốc để làm bản Electron. `sample` trên một WebContent đang 100.7% CPU:

| Frame | Số mẫu |
| --- | --- |
| `computeVisibleRectsInContainer` | 400 |
| `performFlexLayout` | 229 |
| `WeakListHashSet<RenderBox>::add` | 167 |
| `addPercentHeightDescendant` | 133 |
| `LayoutRepainter::repaintAfterLayout` | — |

Thời gian nằm **toàn bộ ở layout của WebCore**. Ba thứ đã loại được:

- **Không phải CSS ẩn chrome của app** — không có một frame `SelectorChecker` /
  `styleForElement` / `invalidateStyle` nào; và spike vẫn xảy ra với
  `FBMESS_KEEP_FB_CHROME=1` (4.0 / 3.6 / 18.4 / **60.6** / 4.0 / 3.6 / 3.6 / 3.4%).
- **Không phải memory pressure** — pressure level 1, không có frame page-fault.
- **Không sửa được từ phía shell** — layout thrash nằm trong WebCore. App wrapper không có
  đường can thiệp.

### CPU — có confound, đọc kỹ

| Engine | Điều kiện | Thời lượng | Trung bình cả đời process |
| --- | --- | --- | --- |
| WKWebView | **dùng thật** | 4h | 9.2% |
| Blink | **idle** | 25.78h | renderer 0.91% · cả cây 1.19% |

**Confound chưa khử được:** Blink đo lúc idle, WKWebView đo lúc đang dùng. Soak WKWebView
idle đối chứng (khởi động 09:13) đã chết trước khi ra dữ liệu — không có CSV.

Thêm một điểm không nên bỏ qua: Blink **không phẳng** theo thời gian. Ở mốc 14.24h cả cây
là 0.78%; ở 25.78h là 1.19%. Suy ra nửa sau chạy ~1.72%, tức tăng gấp đôi. Vẫn thấp hơn
WKWebView một bậc độ lớn, nhưng đừng trích "0.58%" như một hằng số.

### Memory — chưa kết luận được

| Mốc đo | WKWebView | Blink |
| --- | --- | --- |
| Soak idle dài | 659.1 MB (1 kênh, lúc bắt đầu) | 499 MB (1 kênh, sau 14h; đi từ 600.7 → 334.8) |
| Một lần đo trước đó | ~730 MB | 799 MB |
| Cửa sổ mở, dùng thật | ~990 MB | chưa đo |
| Riêng shell | 28 MB | chưa tách được |

Hai lần đo cho hai chiều ngược nhau. **Không dùng memory làm căn cứ chọn.**

## Phương án

| | A. Electron chính, Swift đóng băng | B. Swift chính, bỏ Electron | C. Song song, cả hai đều chính | D. Chrome app mode thay Electron |
| --- | --- | --- | --- | --- |
| Sửa được freeze | Có | **Không** — nằm trong WebCore | Có, nhưng chỉ ở nửa Electron | Có |
| Chi phí feature mới | ×1 | ×1 | **×2** + mirror tay dễ lệch | ×0 (không code) |
| Bundle / phân phối | 276 MB, phải tự lo update | 1.2 MB | cả hai | 0 (dùng Chrome đã cài) |
| Notification | native | shim `window.Notification`, **điểm dễ vỡ nhất** | cả hai | native |
| Mất gì | knob đo (`MODE`/`TOPOLOGY`/`UA`/`WINDOW`) — đều đã ra kết quả âm | freeze còn nguyên | không mất | rail, tray, badge unread, hotkey, ẩn chrome |
| Công phải làm | port ⌘0; xác minh notification | 0 | duy trì mirror mãi | viết lại từ đầu nếu muốn có rail |

D loại ngay: mất rail + badge unread, mà badge unread từng là tính năng bạn hỏi đầu tiên.

B loại: freeze là lý do duy nhất khiến project này rẽ sang Electron, và nó nằm ở tầng
không sửa được. Chọn B là chấp nhận sống với freeze.

C là mặc định đang chạy, và là phương án tệ nhất về lâu dài: `02a7556` đã cho thấy mỗi thay
đổi service phải sửa hai nơi, không có test nào bắt được lệch giữa `Services.swift` và
`services.js`.

## Đề xuất: A

**Electron thành bản chính. Swift đóng băng — nhưng KHÔNG xoá bản đã cài trên MacBook.**

Lý do giữ nguyên app Swift đã cài dù ngừng phát triển: lịch sử E2EE cục bộ nằm trong
`~/Library/WebKit/<bundle-id>/`. Tin nhắn mã hoá đầu-cuối chỉ giải mã được từ store của
đúng thiết bị đó. Xoá app là mất đường đọc lịch sử cũ — server không giữ bản rõ. Để nó nằm
đó, dung lượng 1.2 MB.

"Đóng băng" nghĩa là: không thêm tính năng, không port tính năng mới sang; vẫn sửa nếu vỡ.

## Rủi ro mở — phải trả lời trước khi ship rộng

| Rủi ro | Vì sao đáng lo | Cách kiểm | Nếu sai thì sao |
| --- | --- | --- | --- |
| **Chưa đo Electron với 4 kênh cùng lúc** | Soak 25.78h chỉ 1 kênh. 4 kênh = 4 renderer process. Số 499 MB là của một kênh | Chạy đủ 4 kênh đã login, `measure.sh` | 4× có thể vỡ trên 16 GB → phải lazy-load kênh chưa xem |
| **Chưa đo gì trên MacBook Pro M1 16GB** | Mọi số hiện có đều từ Mac mini M4 24GB. Máy dùng thật yếu hơn và ít RAM hơn | `--probe` + `measure.sh` trên MacBook | Nếu Blink cũng freeze ở đó thì cả A lẫn B đều thua, phải brainstorm lại |
| **Notification Electron chưa thấy hoạt động thật** | Chỉ mới cấp quyền qua `setPermissionRequestHandler`. Chưa có notification nào thực sự đến | Login rồi nhờ ai nhắn tin lúc cửa sổ ẩn | Mất tính năng cốt lõi — app resident mà không báo tin thì vô nghĩa |

Rủi ro 3 đáng chú ý: bản Swift **cũng** chưa từng xác minh notification khi app ẩn lâu
(`README.md` mục "Hạn chế đã biết" số 4). Nên đây không phải điểm trừ riêng của A, nhưng
đừng coi là đã có.

## Self-review

| Mục | Kết quả |
| --- | --- |
| Tenant isolation | Không áp dụng — app client một người dùng, không có `merchant_id` |
| PII / compliance | Không thêm đường dữ liệu mới. Cả hai bản đều chỉ render web app chính thức của Meta |
| Breaking change | Có: phải login lại 4 kênh trong bản Electron, và lịch sử E2EE không theo sang |
| Over-engineering | A là phương án **bớt** đi (một bản thay vì hai). Ngược hướng over-engineering |
| Đơn giản hơn được không | Có — D đơn giản nhất nhưng mất tính năng đã dùng |
| Trùng lặp logic | Chính vấn đề đang giải: `services.js` mirror tay `Services.swift` |
| Observability | `--probe`, `--version`, `selftest.js`, `preview-rail.js` đều đã có ở bản Electron |

## Tiêu chí thành công

A coi là đúng khi cả ba điều sau đúng trên **MacBook Pro M1 16GB**:

1. Dùng liên tục 1 tiếng với 4 kênh, không có lần nào không bấm được vào nội dung.
2. Nhận được notification khi cửa sổ đang ẩn.
3. Footprint 4 kênh không làm máy swap (theo dõi bằng `measure.sh --watch`).

Sai bất kỳ điều nào → mở lại quyết định, không cố cứu.

## Bước tiếp

Quyết định này chốt xong mới sang hai chủ đề còn lại, vì cả hai đều đổi phạm vi theo nó:

- **Phân phối / auto-update** — nếu A thì chỉ cần một kênh update cho bản Electron 129 MB.
  Nếu C thì hai kênh.
- **Unread cắm được theo service** — nếu A thì sửa một chỗ. Nếu C thì sửa cả
  `unreadFromTitle` của JS và bản Swift tương ứng.
