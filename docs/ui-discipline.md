# Kỷ luật UI: soi DOM và AppKit

App này ẩn chrome của 3 web app do người khác viết, và dựng UI native quanh chúng. Cả hai
việc đều đã sinh ra lỗi *tự tin mà sai* — code trông đúng, chạy sai, và công cụ kiểm tra
xác nhận sai. Ghi lại để không lặp.

## Nguyên tắc

1. **Không đoán selector.** Soi DOM thật rồi mới viết. Bốn lần đoán trong dự án này, bốn
   lần sai — chi tiết dưới.
2. **Không đoán đường dẫn.** Suy diễn từ site khác đã hai lần cho kết luận sai.
3. **Không đoán layout.** Đo `frame`, `constraints`, `alignmentRectInsets`. Ba lần đoán
   liên tiếp đều sai trước khi chịu đo.
4. **Công cụ kiểm tra phải chạy đúng code sẽ ship.** Nếu nó dựng lại thì nó sẽ nói dối.
5. **Ưu tiên `href` hơn `aria-label`.** href độc lập ngôn ngữ và tài khoản. Chỉ khi không
   có href mới dùng aria-label, và phải **khớp chính xác**.

## Bẫy selector đã mắc

### `[role="navigation"]` không phải chrome

| Site | `[role="navigation"]` thực ra là gì |
| --- | --- |
| facebook.com/messages | **3** vùng: thanh tab, account controls, và **thread list** |
| instagram.com/direct | **Chính panel danh sách hội thoại** (dòng chat 362×72), không phải rail trái |

Rule "hiển nhiên" `[role="navigation"] a:not([href*="/direct"])` sẽ **xoá sạch danh sách
chat** trên Instagram. Rail trái nằm *ngoài* vùng navigation.

### Match `*=` trên `aria-label` trúng nội dung người dùng

`[role="button"][aria-label*="Facebook" i]` khớp cả **một tin nhắn** — vì nội dung tin nhắn
cũng được đưa vào `aria-label`. Luôn khớp chính xác.

### Selector cấu trúc trúng luôn UI cần giữ

`input[role="combobox"]` khớp cả ô **`Search Messenger`** của chính Messenger. Ẩn nó là mất
tìm kiếm hội thoại.

### Ẩn con mà không ẩn cha

Ẩn `input[aria-label="Search Facebook"]` không làm nút biến mất: cái nhìn thấy được là
`<label>` bọc ngoài (40×40, `border-radius: 50px`). Selector đúng:

```css
*:has(> input[aria-label="Search Facebook"])
```

**Bắt buộc có `>`.** Thiếu dấu đó thì `:has()` khớp mọi ancestor tới tận `<body>` — ẩn sạch
trang.

### Class hash và id động thì vô dụng

`#mount_0_0_wK > … > div.x9f619.x1n2onr6…` không dùng được: hậu tố `wK` là token random
**mỗi lần load**, còn `x9f619` là class atomic do Stylex sinh lúc build, đổi theo mỗi deploy.

Và quan trọng hơn: **ẩn DOM không giảm memory.** Node vẫn tồn tại, React vẫn render và
diff. Lợi ích thật chỉ là chặn lỡ tay click vào surface nặng (Reels/Marketplace/Explore).

## Đường dẫn: hai lần suy diễn sai

| Suy diễn | Thực tế |
| --- | --- |
| Threads DM ở `/direct/` (theo Instagram) | `/messages/`. `/direct` redirect về feed → tôi kết luận sai là "Threads không có DM" |
| `m.facebook.com` / `mbasic` cho bản nhẹ | Cả hai redirect về `www` bất kể UA — Meta đã bỏ |

## Bẫy AppKit đã mắc

### `NSButton.alignmentRectInsets` khác 0

Auto Layout ràng buộc **alignment rect**, không phải frame. Đo được insets top 6 / bottom 4
(đổi theo SF Symbol), nên:

```
height = 48    →  frame thật 48 + 6 + 4 = 58
gap    = 10    →  khe hở thấy được 10 − 4 − 5 = 1px
```

Layer — thứ thực sự được vẽ — dùng **frame**. Kết quả: tile to hơn khai báo và dính liền
nhau. Sửa bằng subclass override `alignmentRectInsets` về 0.

Bài học phụ: kết luận đầu của tôi là "NSStackView bỏ qua `spacing`". Sai — insets đã ăn nó.

### SF Symbol mất accessibility label

`NSImage(systemSymbolName:accessibilityDescription:)?.withSymbolConfiguration(...)` trả về
**image mới** và làm mất description. Nút icon-only thành không có label cho screen reader.
Đặt `setAccessibilityLabel` thẳng trên nút.

Cũng lưu ý: không set `pointSize` thì SF Symbol render ở cỡ mặc định, nhỏ hẳn so với tile.

### Màu semantic phải resolve trong đúng appearance

`NSColor.windowBackgroundColor.cgColor` chốt giá trị theo appearance **hiện tại của
process**. Set ngoài block appearance thì bản render "dark" ra y hệt bản light.

```swift
appearance.performAsCurrentDrawingAppearance {
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    // … style + draw
}
```

Và **tile phải dùng màu đục**: alpha phủ lên nền không biết trước làm light mode nhạt toẹt,
tile inactive lại nổi hơn active.

### Menu dựng trước khi dữ liệu tồn tại

`buildMenu()` chạy trước `buildUI()`, nên điều kiện `runtimes.count > 1` luôn sai và menu
chọn kênh **không bao giờ được thêm**. Dựng menu từ `services` (tồn tại lúc init) thay vì
từ `runtimes`.

Cùng loại: item tick so `tag` với `activeIndex` cho *mọi* item, mà item toggle có `tag = 0`
mặc định nên bị tick khi đang ở kênh đầu. Lọc theo `action`.

## Công cụ

### Probe DOM trong app

`FBMESS_DIAG=1` bật probe chạy **trong webview thật, với session thật**. Không dùng
Playwright vì nó điều khiển browser riêng của nó, không có cookie của app, và câu hỏi luôn
là "app *của mình* thấy DOM gì".

Ba lỗi probe đã sinh dữ liệu sai một cách tự tin:

| Lỗi | Hệ quả |
| --- | --- |
| Gọi `self.webView` (view đang active) thay vì view vừa load | Instagram và Threads trả về DOM **giống hệt từng pixel**, chỉ khác nhãn |
| Một flag `loggedDiagnostics` dùng chung | Chỉ service load xong **đầu tiên** được probe |
| Probe hình dạng Facebook (chỉ quét `top<60px` + ARIA landmark) | Rail **dọc** của Instagram đọc ra rỗng hoàn toàn |

Probe không đọc nội dung hội thoại: loại trừ `[role="grid"]`, chỉ lấy `href` + `aria-label`
của phần tử điều hướng.

### Preview UI không cần chạy app

```bash
./preview-rail.sh out.png     # trái = light, phải = dark
```

`screencapture` đòi quyền Screen Recording nên không dùng được. Script này compile kèm
`Sources/Messenger/RailView.swift` và gọi **đúng** `Rail.make`/`Rail.style` mà app dùng.

Bản preview đầu tiên tự dựng lại UI bằng frame thủ công — khoảng cách luôn đúng, nên nó
**không thể** phát hiện lỗi `alignmentRectInsets` của app. Preview mà không chạy code thật
thì tệ hơn không có preview, vì nó tạo cảm giác đã kiểm tra.

### Self-check cho CSS ẩn chrome

Mỗi rule được đếm số element khớp sau khi load, log cảnh báo nếu bằng 0. Chạy **2 mốc
(8s và 25s), chỉ cảnh báo ở mốc sau** — nav của Threads render trễ nên mốc sớm luôn báo
thiếu, mà cảnh báo luôn sai thì người dùng quen bỏ qua cảnh báo thật.

Kill switch `FBMESS_KEEP_FB_CHROME=1` vừa để tắt khi rule khớp nhầm, vừa là cách chạy A/B
kiểm tra rule có phá layout chat không.

### Verify bằng Accessibility, không tin code "trông đúng"

```bash
osascript -e 'tell application "System Events" to tell process "FB Mess" \
  to get name of menu items of menu 1 of menu bar item "Service" of menu bar 1'
```

Menu query hoạt động ổn định. Query **window** thì có lúc trả về 0 window dù cửa sổ vẫn
hiện — kiểm tra chéo bằng `CGWindowListCopyWindowInfo` trước khi kết luận app lỗi.
