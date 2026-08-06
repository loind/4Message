# Logo 4 chấm cho 4Message

Tên app đổi thành 4Message nhưng logo vẫn 3 chấm. Vẽ lại 4 chấm, và làm cả hai asset —
`Resources/AppIcon.icns` (app icon, full màu) và `electron/tray.png` (menu bar, đơn sắc).

## Chốt

| Hạng mục | Quyết định |
| --- | --- |
| Bố cục chấm | **2×2**, không phải hàng 4 |
| Palette | Plate `#4a84ff`; chấm `#4a84ff` `#e84190` `#57575f` `#12b3a8` |
| Đuôi | Bezier gốc của icon đang ship (nhọn, có sweep) |
| Tray | Cùng hình, 4 chấm, đơn sắc, glyph tràn khung |

## Vì sao 2×2 chứ không phải hàng 4

Đo được, không đoán: hàng 4 chấm ở **48px** nhoè thành một vạch gần liền, còn 2×2 thì bốn
chấm vẫn tách rời ở cùng cỡ. Lý do là bề rộng bubble cố định — thêm chấm thứ tư vào một
hàng buộc bán kính rơi từ 46 xuống 34 và khe hở co lại; xếp vuông thì mỗi chấm giữ được
bán kính lớn.

## Vì sao zalo đổi sang teal

Ý ban đầu là 4 chấm mang đúng 4 màu thương hiệu. Nhưng Meta và Zalo đều dùng xanh:
plate `#4a84ff`, messenger `#4a84ff` (trùng hệt plate), zalo `#0068ff`. Ở 48px messenger và
zalo đọc thành một màu — logo *nói* 4 kênh mà *đọc* ra 3.

Đổi zalo sang teal `#12b3a8` cho bốn tông rõ rệt. Đánh đổi: màu Zalo không còn đúng
thương hiệu. Đã cân nhắc hai đường khác và loại: đổi plate sang indigo (vẫn còn hai chấm
xanh giống nhau), và bỏ hẳn ý 4 màu (logo không nói được gì về 4 kênh).

## Cân bằng quang học

Bubble căn giữa theo toán **không** có nghĩa căn giữa theo mắt: đuôi chĩa xuống-trái kéo
khối mực chìm. Hai thước đo xung đột và không thể cùng bằng 0 với hình có đuôi mảnh:

- **bbox cân** → khối mực bị đẩy lên cao 3-4%
- **centroid cân** → silhouette nhìn chìm xuống

Chọn **điểm giữa hai nghiệm** để sai số lớn nhất nhỏ nhất. Với đuôi bezier gốc: nudge 35,
còn lại centroid +23, bbox −46. Đuôi càng dài thì residual càng lớn — đó là giá của việc
giữ đuôi cũ.

Ngang thì cân thật: lề trái/phải lệch 0.2%.

`tools/icon-balance.swift` đo và vẽ đường gióng để kiểm lại bất cứ lúc nào.

## Tray: hình học RIÊNG, không tái dùng tỉ lệ app icon

App icon có plate nên bubble chỉ chiếm ~46% khung. Tray không có plate — giữ tỉ lệ đó thì
ở 20px bubble chỉ còn ~9px và bốn chấm biến mất. Tray phải scale glyph cho bbox tràn khung,
chừa lề mảnh.

Tray là **template image**: chỉ đen + alpha, macOS tự đảo màu theo menu bar sáng/tối. Chấm
phải là **lỗ alpha thật** (`destinationOut`), không phải chấm màu trắng — vẽ trắng thì khi
đảo màu nó thành khối trắng đặc.

Hạn chế đã biết và chấp nhận: ở 20px mỗi chấm chỉ ~2px. Bốn chấm đọc được thành cụm nhưng
từng chấm ở sát giới hạn; nền tối đọc tốt hơn nền sáng.

## Ràng buộc giữ nguyên từ icon cũ

Thiết kế gốc. **KHÔNG** dùng logo Messenger của Meta (trademark), **KHÔNG** dùng SF Symbols
(license cấm dùng symbol làm app icon).

## Đã loại

- **Liquid Glass native macOS 26** (`.icon` bundle) — máy này không có Xcode/Icon Composer,
  `iconutil` chỉ biết `icns`/`iconset`, và app hệ thống trên máy vẫn dùng `.icns`. Không
  làm được thì không hứa.
- Hàng 4 chấm — đo ở 48px thấy nhoè.
- Chấm cùng một màu — mất ý nghĩa "4 kênh".
