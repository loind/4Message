# Brainstorm: có nên thay engine WKWebView?

**Ngày:** 2026-08-03 · **Trạng thái:** chờ một phép đo quyết định trước khi chốt

## Vấn đề

Nội dung web đóng băng, không bấm được. Cửa sổ và menu vẫn phản hồi — chỉ WebContent
process bị chặn. User đề xuất thay engine, ví dụ Chromium.

Máy xảy ra lỗi: **MacBook Pro M1, 16 GB** (không phải Mac mini dev — xem memory
`dev-machine-vs-usage-machine`).

## Đã đo được gì

Bắt được repro trên Mac mini: WebContent **100.7% CPU**, footprint 1717 MB.
`sample` cho thấy thời gian tiêu **hoàn toàn trong layout**:

```
RenderBox::computeVisibleRectsInContainer      400
RenderFlexibleBox::performFlexLayout           229
WTF::WeakListHashSet<RenderBox>::add           167
RenderBlock::addPercentHeightDescendant        133
RenderBox::computeLogicalHeight / contentBoxWidth
RenderBlockFlow::layoutBlock · LayoutRepainter::repaintAfterLayout
```

Đây là **layout thrash** trên cây flexbox có percentage-height của Facebook.

CPU tức thời (delta cputime / 5s) khi **tắt** CSS ẩn chrome:

```
4.0 · 3.6 · 18.4 · 60.6 · 4.0 · 3.6 · 3.6 · 3.4  (%)
```

Nên: **không phải treo vĩnh viễn mà là spike layout theo đợt** — nền ~4%, bùng lên 60–100%.
Trong lúc bùng thì nội dung không phản hồi. Trên M1 16 GB, đợt bùng sẽ dài hơn.

## Hai giả thuyết bị bác bỏ

| Giả thuyết | Bác bỏ bằng |
| --- | --- |
| CSS `*:has()` của tôi gây style-recalc storm | Stack **không có** `SelectorChecker`/`styleForElement`/`invalidateStyle`; và spike **vẫn xảy ra** khi `FBMESS_KEEP_FB_CHROME=1` |
| Thiếu RAM trên máy 16 GB | `memorystatus_vm_pressure_level = 1`; stack không có page fault / compressor |

Trước đó tôi đã đẩy lại ý "đổi engine" hai lần dựa trên hai giả thuyết này. Cả hai sai.

## Các hướng

| Tiêu chí | A. Giữ WKWebView + CSS containment | B. Chrome `--app` mode | C. Electron / CEF | D. Safari Web App |
| --- | --- | --- | --- | --- |
| Đổi engine thật | Không | **Có** | **Có** | Không (vẫn WebKit) |
| Chữa layout thrash | Không chắc | Có nếu Blink layout tốt hơn | Như B | **Không** — cùng engine |
| Công sức | ~20 dòng CSS | 0 dòng | **Viết lại toàn bộ app** | 0 dòng |
| RAM thêm | 0 | Chrome tự chạy | **+150–250 MB bundle** | 0 |
| Giữ menu bar resident, ⌘⇧M, badge, rail | Có | **Mất hết** | Phải làm lại | Mất |
| Notification | Shim hiện tại | Của Chrome | Phải làm lại | **Web Push thật** |
| Bảo trì | Thấp | Không có | **Tự lo update Chromium** | Không có |

**Tauri không phải lựa chọn:** trên macOS Tauri dùng chính `WKWebView`. Đổi mà không đổi
engine.

**C là quay về Franz.** Chính Electron + Chromium bundle là thứ dự án này bỏ đi, và trên máy
16 GB đang giữ 1.2 GB thì nó đi ngược hướng.

**D vô nghĩa cho vấn đề này** vì cùng engine — nhưng vẫn đáng nhắc nếu sau này muốn Web Push
thật thay cho shim.

## Thử đo Chrome trên Mac mini: KHÔNG thực hiện được

Ghi lại để không thử lại theo cách đó.

| Việc | Kết quả |
| --- | --- |
| `open -na "Google Chrome" --args --app=…` | Instance thứ hai kẹt profile lock → Chrome chạy mà **0 cửa sổ**, AppleScript timeout |
| Tắt hết Chrome rồi `open -a` profile thật | Vẫn **0 cửa sổ**, không sinh renderer nào |
| Đo "renderer của Chrome" | **Đo nhầm process của app khác** — xem dưới |

**Lỗi nghiêm trọng nhất, suýt báo sai:** `pgrep -f 'Helper (Renderer)'` khớp renderer của
**mọi app Electron**. Con số "205.9 MB / 0.0% CPU" tôi gần trình bày là "Chrome mượt" thực
ra là renderer của **Orca**; cái còn lại là **Bitwarden**. Chrome chưa hề render gì.

Hai bug phụ trong cách đo tay:
- `(Renderer)` trong `pgrep -f` là **regex group**, không phải literal → pattern không khớp.
- Viết pattern thẳng trong pipeline `ps | grep` làm `ps` bắt luôn **chính các process grep**
  → đếm ra renderer trong khi Chrome tắt hẳn. Phải dùng bracket trick `[G]oogle`.

`chrome-probe.sh` sửa cả ba, và **bắt buộc xác nhận có cửa sổ + footprint đủ lớn** trước khi
đo — renderer 0% CPU có thể chỉ là tab nền hoặc trang login.

### Một dữ kiện thu được miễn phí về hướng C

Máy này đang chạy sẵn hai app Electron: **Orca renderer 207 MB**, **Bitwarden 135 MB** —
chưa tính main + GPU + network process của mỗi app. Đó là chi phí RAM thực tế của Electron
trên chính máy user, không phải con số tôi suy ra.

## Đề xuất

**Chưa viết code. Đo xem Chromium có thật sự tốt hơn trước đã.**

Lý do: toàn bộ luận điểm "Chromium mượt hơn với Facebook" hiện dựa trên suy lý (Meta phát
triển chính trên Chrome), **không có số nào từ máy này**. Mà A, B, C khác nhau hàng chục
đến hàng nghìn dòng code — quyết định sai thì đắt.

Phép đo (trên **MacBook**, nơi có lỗi):

```bash
# Trên MacBook, đóng Chrome trước (script sẽ báo nếu còn chạy)
./chrome-probe.sh
```

Script tự làm attribution đúng, xác nhận cửa sổ tồn tại, cảnh báo nếu đang ở trang login,
rồi in 8 mẫu delta cputime kèm mốc so sánh WKWebView.

| Kết quả | Kết luận |
| --- | --- |
| Chrome **không** spike | Engine đúng là nguyên nhân → bàn tiếp A/B/C với dữ liệu thật |
| Chrome **cũng** spike | Là app web của Facebook, **không engine nào chữa** → chuyển sang giảm thiểu (hướng A) hoặc chấp nhận |

Nên chạy thêm một control: cùng URL trong **Safari** trên MacBook. Nếu Safari cũng spike thì
xác nhận đây là WebKit+Facebook nói chung, không phải cấu hình webview của app.

## Self-review

- Tenant isolation / event schema / DB index / Kafka: **không áp dụng** — app desktop, không
  backend.
- Breaking change: hướng B và C **mất** menu bar resident, global hotkey, badge, rail đa kênh.
- PII: các script chẩn đoán chỉ đọc `href`/`aria-label` phần điều hướng và số đếm element,
  không đọc nội dung hội thoại.
- Observability: `freeze-sample.sh` đã có để chụp stack lúc treo.
- YAGNI/KISS: hướng đề xuất là **đo trước, 0 dòng code**.
- DRY: `freeze-sample.sh` dùng lại attribution của `measure.sh` — nên tách shared lib nếu
  còn thêm script thứ ba (đã từng vì duplicate mà sửa một chỗ quên chỗ kia).

## Rủi ro

- MacBook đang chạy **build 10 (`8e3f1ca`)**, lùi 12 commit. Build đó **đã có** fix link nên
  không phải nguyên nhân treo, nhưng mọi kết luận sau này phải ghi rõ build nào.
- Spike theo đợt nên dễ đo sai thời điểm. Phải đo bằng delta cputime nhiều mẫu, không dùng
  `ps -o pcpu` (đó là trung bình từ lúc process sinh ra).
- `freeze-sample.sh` fallback attribution có thể bắt nhầm WebContent của app khác — luôn đối
  chiếu PID với `measure.sh`.

## Tiêu chí thành công

Nội dung không còn đợt đóng băng nào dài hơn ~1 giây trong 30 phút dùng bình thường, đo bằng
delta cputime của WebContent giữ dưới ~30%.

## Quyết định chưa chốt

Chọn A, B hay C — **cần số của Chrome trên MacBook trước**. Không tự chốt thay user.
