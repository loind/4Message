# Bật/tắt kênh lúc chạy + ẩn rail

Ba việc ghép thành một tính năng:

1. Menu chọn kênh nào bật, ở thanh menu.
2. Tắt kênh → giải phóng RAM của kênh đó.
3. Ẩn rail: tự động khi chỉ còn 1 kênh bật, và ẩn tay được (⌘0).

## Trạng thái hiện tại

| Điểm | Hiện tại | Ý nghĩa |
| --- | --- | --- |
| Danh sách kênh | `resolveServices(FBMESS_SERVICES)` chạy một lần lúc khởi động (`electron/main.js:17`) | Không đổi được lúc chạy |
| `runtimes[]` | Dựng một lần, mỗi kênh một `WebContentsView` (`main.js:159-161`) | Mọi kênh đều tốn RAM dù không xem |
| Kênh đang xem | `activeIndex` — **số nguyên** trỏ vào `runtimes[]` | Mảng co giãn là mọi index đang giữ đều lệch |
| Ẩn rail | `railW = services.length > 1 ? RAIL_WIDTH : 0` (`main.js:52`) | Theo danh sách lúc khởi động, không theo trạng thái bật/tắt |
| Ẩn rail bằng tay | không có | Bản Swift đã có ⌘0 + `UserDefaults` (`main.swift:719-728`) |

## Hai quyết định đã chốt

**Tắt kênh = destroy view**, không phải chỉ ẩn tile. Lý do: một kênh Messenger đã ~500 MB, máy dùng là M1 16GB. Hệ quả phải nói thẳng: **kênh tắt không báo tin nữa** và bật lại phải load lại ~5–10s.

**Ẩn rail bằng tay tách rời khỏi quy tắc "còn 1 kênh"**. Chính vì destroy làm mất thông báo, gộp hai thứ này lại sẽ buộc người dùng chọn giữa "rail gọn" và "còn nhận tin". Tách ra thì giữ được cả 4 kênh sống mà vẫn ẩn được rail.

## Phương án: đổi danh tính từ index sang `id`

`runtimes[]` vẫn chỉ chứa kênh **đang bật**, đúng như bây giờ. Thay `activeIndex` (số) bằng
`activeId` (chuỗi) và derive index qua helper.

Hai hướng đã loại:

| | Vì sao loại |
| --- | --- |
| Map `id → {view, unread}`, viết lại vòng đời | ~100 dòng, chạm hầu hết `main.js`. Với tối đa 4 phần tử thì Map không mua thêm gì so với mảng + `activeId` |
| Ghi config rồi `app.relaunch()` | ~15 dòng nhưng restart mất vị trí cửa sổ và load lại cả 4 kênh — đúng cái phiền mà app này sinh ra để tránh |

## Kiến trúc

### Lưu trạng thái

`prefs.json` trong `app.getPath('userData')`:

```json
{ "enabled": ["messenger", "instagram"], "railCollapsed": false }
```

Không thêm dependency. File thiếu hoặc hỏng → về mặc định, **không crash**: đây là file người
dùng có thể sửa tay và là đường vỡ dễ nhất của tính năng này.

### Ba quy tắc thuần — đặt trong `services.js`

Đặt ở đó để `selftest.js` test được không cần GUI, mạng, hay login. Đây là cổng build.

| Hàm | Hợp đồng |
| --- | --- |
| `resolveEnabled(universe, prefs)` | Bỏ id lạ, giao với universe từ `FBMESS_SERVICES`, rỗng → về toàn bộ universe. **Không bao giờ trả 0 kênh** |
| `railVisible(enabledCount, collapsed)` | `enabledCount > 1 && !collapsed` |
| Thứ tự rail | Luôn theo thứ tự canonical trong `SERVICES`, không theo thứ tự bấm bật |

`FBMESS_SERVICES` vẫn là **vũ trụ** kênh khả dụng; prefs chỉ bật/tắt trong vũ trụ đó. Nên
`FBMESS_SERVICES=messenger,instagram` thì prefs có ghi `zalo` cũng bị bỏ.

### Vòng đời view

- **Khởi động**: chỉ dựng view cho kênh đang bật. Kênh tắt không tạo view — không phải tạo
  rồi hủy.
- **Tắt**: `removeChildView` → `webContents.destroy()` → splice khỏi `runtimes`.
- **Bật**: tạo view, `loadURL`, chèn vào `runtimes` đúng vị trí canonical.

Destroy **không làm logout**: session nằm ở partition `persist:fbmess`, không nằm trong view.
IndexedDB và khoá E2EE còn nguyên.

### Menu

Checkbox từng kênh ở **cả hai** bề mặt:

- App menu bar — menu mới **"Kênh"**.
- Tray menu — đã tự rebuild mỗi 5s (`main.js:202`) nên tick tự đồng bộ.

Thêm ⌘0 ẩn/hiện rail, nhãn đổi theo trạng thái như bản Swift: `Ẩn cột kênh` ↔ `Hiện cột kênh`.

## Edge case

| Tình huống | Xử lý |
| --- | --- |
| Tắt kênh cuối cùng | Menu item **disable** khi `enabled == 1`. Không cho tắt |
| Tắt kênh đang xem | Nhảy sang kênh bật đầu tiên theo thứ tự canonical |
| ⌘1–4 | Trỏ kênh bật thứ N — đúng vị trí trên rail. Không stable theo service |
| Bật lại kênh | `did-finish-load` tự chèn lại CSS ẩn chrome, không cần đường riêng |
| `prefs.json` hỏng | Về mặc định, log cảnh báo, không crash |
| ⌘0 khi chỉ có 1 kênh | Không có tác dụng thấy được — `railVisible` vẫn false |
| Badge tổng | Chỉ tính kênh đang bật. Kênh tắt không có view nên không có title để đọc |

## Cách xác minh

| Tầng | Kiểm gì |
| --- | --- |
| `selftest.js` (cổng build) | `resolveEnabled` với: id lạ, ngoài universe, rỗng, trùng. `railVisible` cả 4 tổ hợp |
| `--probe` | Số tile rail khớp số kênh bật; view của kênh tắt **không tồn tại** |
| Tay, trên máy dùng | Tắt kênh → `measure.sh` thấy footprint giảm. Bật lại → kênh load và vào đúng vị trí rail |
| `preview-rail.js` | Rail 1 tile / 2 tile / 4 tile render đúng ở cả light và dark |

Điểm đáng đo nhất: **footprint có giảm thật khi tắt kênh không.** Nếu `webContents.destroy()`
không trả RAM về ngay (bmalloc trả page chậm — đã gặp ở bản WKWebView), thì cả lý do chọn
destroy sụp, và phương án lùi về "chỉ ẩn tile".

## Không làm (YAGNI)

- Tùy chọn "giữ kênh này chạy nền dù đã tắt" — mỗi kênh một chế độ riêng là hai trục cấu hình cho một app một người dùng.
- Kéo thả sắp lại thứ tự rail — thứ tự canonical đủ dùng.
- ⌘N stable theo service — đã cân nhắc và loại: ⌘4 trỏ kênh đang tắt là phím chết.
- Đồng bộ prefs giữa hai máy — hai máy dùng khác nhau là chuyện bình thường.
