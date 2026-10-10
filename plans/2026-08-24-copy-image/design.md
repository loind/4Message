# Copy / lưu ảnh bằng chuột phải — thiết kế

Chốt ngày 2026-08-24. Trạng thái: đã duyệt, chưa triển khai.

## Vấn đề

Không có đường nào mang một ảnh trong chat ra khỏi app. `WebContentsView` của mỗi kênh
không đăng ký handler `context-menu` nào (`electron/main.js:241-302`), và Electron **không**
tự dựng menu chuột phải như Chrome — nó chỉ phát event rồi để app tự quyết. Kết quả: chuột
phải vào ảnh trong Messenger/Zalo không ra gì.

Text thì đã đi được: menu **Sửa** có `role: 'copy'` / `'paste'` (`electron/main.js:419-422`)
nên ⌘C / ⌘V hoạt động ở tầng role. Đó là lý do tính năng này chỉ nói về ảnh.

## Phạm vi

| Trong scope | Ngoài scope |
| --- | --- |
| Menu chuột phải 2 mục trên ảnh: **Copy ảnh**, **Lưu ảnh…** | Copy/paste text — đã chạy qua menu Sửa |
| Cả 4 kênh (messenger, instagram, threads, zalo) | Paste ảnh từ clipboard vào ô soạn tin |
| Save panel macOS có chọn thư mục | Copy địa chỉ ảnh, copy địa chỉ link |
| Case mới trong `selftest.js` + probe mode `--probe-image` | Kéo-thả ảnh ra Finder |

Chuột phải vào chỗ **không** phải ảnh: app không hiện gì, trang tự xử theo cách của nó.

## Nghiệm thu

| Thao tác | Kết quả kỳ vọng |
| --- | --- |
| Chuột phải vào ảnh trong chat | Menu native macOS, đúng 2 mục, không kèm menu của trang |
| **Copy ảnh** | Bitmap vào clipboard; ⌘V dán được sang Notes / Preview / Slack |
| **Lưu ảnh…** | Save panel macOS mở, mặc định thư mục `~/Downloads`, tên file gợi ý có đuôi đúng; chọn nơi lưu rồi ghi ra file mở được |
| Chuột phải vào text / nền / ô soạn tin | Không có menu của app; menu riêng của trang (nếu có) hiện bình thường |
| Chuột phải vào ảnh mà `srcURL` là `blob:` | Menu vẫn hiện, **Copy ảnh** chạy, **Lưu ảnh…** bị disable |
| `node electron/selftest.js` | Exit 0 |
| `--probe-image` | Exit 0, và in ra kết quả đo `hasImageContents` trên ảnh thật của trang |

## Quyết định đã chốt

| Câu hỏi | Chốt | Vì sao |
| --- | --- | --- |
| Lưu ảnh: hỏi hay không hỏi | Hiện Save panel macOS | Kiểm soát được thư mục; và đây là hành vi *mặc định* của Electron nên gần như free |
| Trang cũng có menu riêng trên ảnh | Ưu tiên menu của app, chặn menu của trang tại ô ảnh | Mục tiêu là copy/lưu ảnh cho được; mất mục riêng của Messenger tại chỗ ảnh là đánh đổi chấp nhận |
| Rủi ro "div phủ lên ảnh" | Đo bằng probe trước, không đoán | Xem mục **Rủi ro** |
| Nghiệm thu | selftest + probe tự động | Kỷ luật sẵn có của repo: exit code là cổng, không phải dòng log |

Hai hướng đã loại:

| Hướng loại | Vì sao loại |
| --- | --- |
| Chỉ sửa `main.js`, không đụng preload | Không chặn được menu của trang → hai menu chồng nhau, trái quyết định ở trên |
| Tự tải bytes bằng `net.request` + `clipboard.writeImage` + `dialog.showSaveDialog` | Phải tự lo cookie/redirect/decode cho CDN cần auth (fbcdn, zdn) — viết lại thứ Chromium đã làm đúng. Chỉ hơn ở ca `blob:`, mà ca đó `copyImageAt` vẫn xử được |

## Kiến trúc

### Nhận diện ảnh: hai tầng phải đồng ý một luật

Đây là chỗ nguy hiểm nhất của thiết kế. Preload quyết định "có chặn menu của trang không";
main quyết định "có dựng menu của app không". Hai bên lệch nhau thì chuột phải **chết câm** —
trang bị bịt miệng mà app không thay thế.

File mới `electron/image-menu.js`, logic thuần, KHÔNG import `electron` (để `selftest.js`
gọi được mà không cần GUI):

| Hàm | Trả lời | Gọi ở |
| --- | --- | --- |
| `shouldShowImageMenu(params)` | Có dựng menu không: `params.hasImageContents` và có `srcURL` | `main.js` |
| `canSaveImage(srcURL)` | Mục "Lưu ảnh…" có enable không: chỉ `http:`, `https:`, `data:` | `main.js` |
| `imageMenuTemplate(params, { onCopy, onSave })` | Mảng template menu — label + `enabled` + `click`. KHÔNG import `Menu`, chỉ trả mảng thuần | `main.js` |
| `suggestedFilename(name, mimeType)` | Tên file gợi ý cho Save panel: cắt query, đảm bảo có đuôi | `main.js` |

`imageMenuTemplate` tách ra khỏi `main.js` vì phần **assert** của `--probe-image` phải kiểm
"menu ra đúng 2 mục" mà không được `Menu.popup()` (popup treo test — xem mục **Guard**). Dựng
template inline trong `main.js` thì không có gì đọc lại được để assert.

`suggestedFilename` nhận thêm `mimeType` để xử ca URL fbcdn không có đuôi file: đoán `.jpg`
là sai với ảnh PNG, mà để trống đuôi thì Finder/Preview không biết mở bằng gì.
`DownloadItem.getMimeType()` là nguồn đúng cho việc này. Không có mime và không có đuôi thì
giữ nguyên tên, KHÔNG đoán.

Phía preload dùng đúng một điều kiện: `e.target.tagName === 'IMG'`.

**KHÔNG dùng `closest('img')`.** `<img>` là void element, không có element con, nên `closest`
chỉ leo lên tổ tiên — nó sẽ nhận nhầm khi trỏ vào vùng trống *cạnh* ảnh trong cùng một
container. Lúc đó preload chặn menu của trang nhưng main thấy `hasImageContents === false`
và không dựng gì: đúng ca chết câm. `tagName === 'IMG'` là tập con chặt của thứ Chromium coi
là image context, nên hai tầng không thể lệch theo chiều nguy hiểm.

### Chặn menu của trang: stopPropagation, KHÔNG preventDefault

`service-preload.js` thêm listener `contextmenu` ở **capture phase** trên `window`, chỉ gọi
`stopPropagation()` khi `e.target.tagName === 'IMG'`.

`preventDefault()` là **sai** ở đây: nó chính là thứ báo cho Chromium đừng dựng context menu
— mà menu ta cần chính là menu đó. `stopPropagation()` chỉ khiến handler của trang không bao
giờ nhìn thấy event, còn default behavior giữ nguyên nên `wc.on('context-menu')` vẫn phát.

Preload chạy trước script của trang nên listener của ta đăng ký trước; ở capture phase trên
cùng một target, listener đăng ký trước chạy trước. Cùng kỹ thuật `service-preload.js:16`
đang dùng cho link — không đẻ khái niệm mới trong repo.

### Dựng menu

Trong `makeServiceView()`:

```
wc.on('context-menu', (_e, params) => {
  if (!shouldShowImageMenu(params)) return
  // probe mode: ghi params rồi return, KHÔNG popup
  Menu.buildFromTemplate([
    { label: 'Copy ảnh', click: () => wc.copyImageAt(params.x, params.y) },
    { label: 'Lưu ảnh…', enabled: canSaveImage(params.srcURL),
      click: () => wc.downloadURL(params.srcURL) },
  ]).popup({ window: win })
})
```

`copyImageAt` nhận toạ độ từ chính `params` của event nên không phải quy đổi qua zoom factor
— đây là lý do giữ trigger ở main thay vì gửi `clientX/clientY` từ preload qua IPC.

### Lưu file

`downloadURL` chạy trong đúng session `persist:fbmess`, nên cookie fbcdn/zdn đi kèm sẵn.

Electron **mặc định** hiện hộp thoại lưu khi `DownloadItem` không được set `savePath`. Chỉ
cần một handler `will-download` đăng ký một lần trên session đó, gọi
`item.setSaveDialogOptions({ defaultPath })` với
`defaultPath = path.join(app.getPath('downloads'), suggestedFilename(item.getFilename(), item.getMimeType()))`.

Handler áp cho **mọi** download của session, không lọc theo URL. Hiện app không có đường
download nào khác nên không có gì để lọc; và nếu sau này có thêm, mặc định "vào Downloads,
tên file chuẩn hoá" vẫn là hành vi muốn có. Ghi lại để lần sau khỏi tưởng là thiếu guard.

## Guard bắt buộc cho probe mode

| Guard | Vì sao |
| --- | --- |
| Probe mode KHÔNG `Menu.popup()` | Popup cần GUI session; trên máy build nó chặn process, test treo thay vì fail. Treo tệ hơn fail — CI đứng mãi mà không ai biết vì sao |
| Probe mode KHÔNG để `will-download` mở Save panel | Cùng lý do: panel modal treo test |

## Kiểm chứng

| Tầng | Kiểm gì | Cần login? |
| --- | --- | --- |
| `selftest.js` | Cả 4 hàm của `image-menu.js`. Ca bắt buộc có: `blob:` → `canSaveImage` false nhưng template vẫn 2 mục (mục save `enabled: false`), URL fbcdn đầy query → tên file cắt sạch query, URL không đuôi file + mime `image/png` → thành `.png`, không đuôi và không mime → giữ nguyên tên, `srcURL` rỗng → `shouldShowImageMenu` false | Không |
| `--probe-image` phần **assert** | Inject `<img>` tổng hợp vào trang, `sendInputEvent` chuột phải vào tâm nó → assert `hasImageContents === true`, `srcURL` khớp, menu ra đúng 2 mục | Không |
| `--probe-image` phần **báo cáo** | Quét `<img>` thật của trang, chuột phải vào ảnh lớn nhất, **in ra** `hasImageContents` | Có |

Tách assert / báo cáo là cố ý. Cơ chế Chromium → Electron là deterministic nên assert được.
Còn Messenger có phủ div lên ảnh chat hay không thì chỉ máy đã login mới trả lời được — biến
nó thành assert sẽ làm probe fail oan trên máy build. Đúng cái bẫy `main.js:269-271` đã ghi
lại với self-check chrome: *cảnh báo luôn sai thì người ta quen bỏ qua cảnh báo thật*.

`--probe-image` KHÔNG đụng `prefs.json` nên nằm ngoài ràng buộc thứ tự
`--probe` → `--probe-toggle` → `--probe-prefs`; chạy độc lập lúc nào cũng được. Điều đó phải
ghi vào README, vì ràng buộc thứ tự hiện có là thứ dễ đọc thành "mọi probe đều có thứ tự".

## Assumption chưa kiểm chứng

Ba điều dưới đây đọc từ tài liệu Electron chứ chưa đo trên máy này. Bước đầu của plan triển
khai phải xác nhận từng cái, vì mỗi cái sai đều đổi thiết kế chứ không chỉ đổi code.

| Assumption | Nếu sai thì sao |
| --- | --- |
| `wc.sendInputEvent({ type: 'mouseDown', button: 'right' })` làm Chromium phát `context-menu` lên `webContents` | Phần **assert** của `--probe-image` mất đường kích hoạt. `dispatchEvent(new MouseEvent('contextmenu'))` **không** thay thế được: event `context-menu` của Electron sinh từ đường input thật của browser, không từ event JS tổng hợp — khác hẳn ca link policy ở `main.js:480` (chỗ đó preload nghe DOM event nên `dispatchEvent` đủ). Hết đường thì `--probe-image` rút về chỉ còn phần báo cáo, và nói rõ điều đó trong README |
| Toạ độ `sendInputEvent` tính theo viewport của chính `webContents`, không theo cửa sổ | Bấm lệch sang rail (`RAIL_WIDTH = 68`) hoặc ra ngoài ảnh → `hasImageContents` về `false` và probe FAIL oan. Xác nhận bằng cách inject `<img>` ở toạ độ biết trước rồi so `params.x/y` nhận lại với toạ độ đã gửi |
| Electron hiện Save panel khi `savePath` không set | Ảnh rơi thẳng vào `~/Downloads` không hỏi gì — trái quyết định đã chốt. Lúc đó phải tự `dialog.showSaveDialog` rồi `item.setSavePath()` |

## Kết quả đo (2026-08-25, `--probe-image`, máy CHƯA login)

Ba assumption ở trên: **cả ba đúng**. `sendInputEvent` chuột phải phát được `context-menu`;
toạ độ tính theo viewport của webContents; và bịt menu trang bằng `stopPropagation` không
làm mất event của Electron. Bảy assert PASS.

Ba bug lộ ra trong lúc đo, đều là bug của chính probe chứ không phải của tính năng — ghi lại
vì cả ba đều tạo ra số đo trông y hệt "tính năng hỏng":

| Bug của probe | Triệu chứng giả | Sửa |
| --- | --- | --- |
| `selectId` không chuyển focus, và `sendInputEvent` đòi CỬA SỔ đang focused | Mọi kênh sau kênh đầu báo "không nhận được event context-menu nào" | `app.focus({steal: true})` + `win.focus()` + `wc.focus()` |
| Lọc ảnh chỉ chặn `top/left < 0` | Ảnh cao thò khỏi mép dưới có TÂM ngoài viewport → bấm vào hư không → `mediaType=none` | Đòi tâm ảnh nằm trong `innerWidth × innerHeight` |
| Chỉ ghi menu đã dựng, không ghi params bị loại | "Không ra menu" là một sự im lặng, không tra được nguyên nhân | Ghi `probeRaw` TRƯỚC cổng `shouldShowImageMenu` |

Số đo trên ảnh thật (đều là **trang login**, chưa đăng nhập nên chưa có ảnh chat):

| Kênh | Chồng element tại điểm bấm | `hasImageContents` | Menu |
| --- | --- | --- | --- |
| Instagram | `IMG`>DIV>… | `true` | **CÓ** |
| Messenger | `DIV`>`DIV`>`IMG`>… | `false` | KHÔNG |
| Threads | `SPAN`>DIV>… | `false` | KHÔNG |

Kết luận: cơ chế chạy đúng đầu-cuối (Instagram là bằng chứng), và **rủi ro "div phủ lên ảnh"
là có thật** — Meta phủ element lên cả ảnh minh hoạ của trang login. Chưa biết ảnh CHAT có bị
phủ không; câu đó chỉ máy đã đăng nhập mới trả lời được, bằng chính `--probe-image`.

Không có ca "chết câm" nào: chỗ ảnh bị phủ thì `e.target` là DIV nên preload cũng không chặn,
trang vẫn xử lý bình thường. Lập luận "tập con chặt" ở mục Kiến trúc giữ đúng.

## Vòng 2: vá ca ảnh bị lớp phủ che (2026-08-25)

Số đo trên `userData` THẬT (đã đăng nhập) xác nhận rủi ro: ảnh trong app bị element khác phủ
lên, `hasImageContents` về `false`, menu không hiện. Thiết kế vòng 1 gần như vô dụng trên
Instagram/Threads. Dưới đây là những gì đo được và đường vá đã chọn.

### Cái gì thật sự chặn hit-test

Không phải "bị phủ" là chặn. Đo bằng từng biến thể lớp phủ dựng sẵn:

| Lớp phủ | Chromium thấy ảnh? | Sau `pointer-events: none` |
| --- | --- | --- |
| Không có | có | — |
| Nền trong suốt `rgba(0,0,0,0)` | **có** | có |
| `<a>` bọc ngoài, `<svg>` rỗng | **có** | có |
| Nền đặc | **không** | **có** |
| Nền đặc + `opacity: 0` | **không** | **có** |
| Nền đặc + có text | **không** | **có** |
| `<canvas>` phủ lên | **không** | **có** |
| `background-image` CSS | **có** | có |

Luật: chỉ lớp phủ **tự vẽ ra pixel** mới chặn. Và `pointer-events: none` gỡ được **mọi** ca.

### Hai đường copy đã loại, kèm lý do đo được

| Đường | Vì sao chết |
| --- | --- |
| `net.fetch` + `nativeImage.createFromBuffer` + `clipboard.writeImage` | `nativeImage` **không decode webp và gif** — đo: webp 193 KB tải về HTTP 200, `isEmpty() === true`. Meta serve webp là chính |
| Vẽ `<img>` ra canvas rồi `toDataURL('image/png')` | Canvas bị taint vì ảnh CDN không có CORS header — `SecurityError: Tainted canvases may not be exported`, đo trên ảnh Instagram thật |

Còn đúng một đường: dùng **chính decoder của Chromium**, tức `copyImageAt`. Nên việc phải làm
là khiến hit-test của nó chạm được tới ảnh, chứ không phải tự đi lấy bytes.

### Đường vá

Hai nhánh trong cùng một handler `context-menu`:

| Nhánh | Khi nào | Copy | Lưu |
| --- | --- | --- | --- |
| `native` | `hasImageContents === true` | `copyImageAt(x, y)` | `downloadURL(params.srcURL)` |
| `fallback` | Chromium không nhận ra, nhưng có `<img>` dưới con trỏ | nhấc `pointer-events` của lớp phủ → `copyImageAt` → trả lại | `downloadURL(srcURL)` |

Hai hàm mới trong `image-menu.js`, **bắt buộc tự chứa**:

| Hàm | Việc |
| --- | --- |
| `imageUnderPoint(doc, x, y, minSide)` | Dò `elementsFromPoint` tìm `<img>` đầu tiên đủ lớn. Bỏ ảnh < 16px: pixel theo dõi và spacer nằm rải khắp trang Meta |
| `liftCoversAt(doc, x, y)` | Tắt `pointer-events` mọi element NẰM TRÊN ảnh, gắn hàm khôi phục vào `doc.__fbmessRestoreCovers`, kèm `setTimeout` backstop 3s |

**Tự chứa** không phải khuyến nghị mà là ràng buộc: hai hàm này chạy ở hai nơi — gọi trực tiếp
trong preload, và serialize bằng `toString()` để chạy trong trang qua `executeJavaScript`.
Tham chiếu ra module scope sẽ `undefined` ở nơi thứ hai và hỏng **im lặng** (menu không bao
giờ hiện trên ảnh bị phủ, không lỗi nào in ra). `selftest.js` có một cổng chặn quét mọi tên ở
module scope trong `toString()` của cả hai hàm.

Đây cũng là cách preload và main dùng **chung một luật** thay vì chép lại: preload gọi
`imageUnderPoint(document, e.clientX, e.clientY, MIN_IMAGE_SIDE)` trực tiếp, main chạy đúng
hàm đó trong trang. Không lệch được, nên không có ca chuột phải chết câm.

### Bẫy đua tiến trình trong lúc copy

Hit-test của `copyImageAt` chạy **trong renderer** và không đồng bộ với lời gọi từ main. Trả
`pointer-events` lại ngay sau khi gọi là đua với chính nó: ảnh vừa lộ ra đã bị che lại trước
khi hit-test kịp chạm tới, và Copy im lặng không có gì. Phải chờ một nhịp (400 ms) rồi mới
khôi phục.

Khôi phục nằm trong `finally` và có thêm `setTimeout` backstop phía renderer. Bỏ sót nó để
lại vùng chat **không bấm được** cho tới lúc reload — hỏng nặng hơn nhiều so với copy không chạy.

### Kết quả sau khi vá

| Kênh | Trước | Sau |
| --- | --- | --- |
| Instagram (ảnh 74×74 trong danh sách) | KHÔNG | **CÓ** |
| Threads (ảnh 543×251, `hasImageContents=false`) | KHÔNG | **CÓ**, đi đường fallback |

14/14 assert của `--probe-image` PASS, trong đó ca ảnh bị phủ kiểm tới tận clipboard: bitmap
ra đúng 100×100 và `pointer-events` đã trả lại.

## Rủi ro

| Rủi ro | Hệ quả | Xử |
| --- | --- | --- |
| ~~Messenger phủ `<div>` lên ảnh~~ | ĐÃ XẢY RA, đã vá | Xem mục **Vòng 2**. Đo ra luật thật (chỉ lớp phủ tự vẽ pixel mới chặn), vá bằng `pointer-events` + `copyImageAt` |
| Ảnh bị đặt `pointer-events: none` | `elementsFromPoint` bỏ qua hẳn element đó → `imageUnderPoint` mù, menu không hiện | Chưa gặp (đo được `pointer-events=auto` trên cả Instagram lẫn Threads). Báo cáo của `--probe-image` in `img-trong-chồng` và `pointer-events` của ảnh nên ca này lộ ra ngay. Nếu gặp: đổi `imageUnderPoint` sang quét hình học `querySelectorAll('img')` thay vì `elementsFromPoint` |
| `srcURL` là `blob:` | `downloadURL` không tải được | `canSaveImage` trả `false` → mục "Lưu ảnh…" disable thay vì bấm được rồi im lặng không có gì. Copy vẫn chạy vì `copyImageAt` đọc bitmap đã decode |
| Preload và main lệch luật nhận diện | Chuột phải chết câm — mất cả menu của trang lẫn của app | Luật ở một chỗ (`image-menu.js`); preload dùng điều kiện là tập con chặt |
| Ảnh động (GIF) | `copyImageAt` cho frame tĩnh | Không xử. "Lưu ảnh…" giữ nguyên file gốc nên vẫn còn đường lấy GIF động |

## File đụng tới

| File | Việc |
| --- | --- |
| `electron/image-menu.js` | **Mới.** Logic thuần: 3 hàm ở bảng trên |
| `electron/main.js` | Handler `context-menu` trong `makeServiceView()`, handler `will-download` trên session, probe mode `--probe-image` |
| `electron/service-preload.js` | Listener `contextmenu` capture-phase, `stopPropagation` khi target là `<img>` |
| `electron/selftest.js` | Case cho 3 hàm mới |
| `electron/README.md` | Bảng **File**, mục **Kiểm tra** (kèm ghi chú `--probe-image` ngoài ràng buộc thứ tự) |
| `README.md` (gốc repo) | Bảng **Dùng**: thêm dòng chuột phải vào ảnh |

Không thêm dependency. `app.asar` tăng khoảng 2 KB — code app hiện 52 KB, chiếm 0.02% bundle
nên dung lượng không phải yếu tố cân nhắc ở đây.

## Ghi chú

Bản `4Message-electron-b74` trong `~/Downloads` **không phải git repo** (`git rev-parse` báo
`not a git repository`), nên design doc này không commit được tại đây. Chuyển về cây git thật
rồi commit nếu muốn giữ vào history.
