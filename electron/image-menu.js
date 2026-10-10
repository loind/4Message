// Menu chuột phải trên ảnh: Copy ảnh / Lưu ảnh. Logic thuần, KHÔNG import `electron` —
// selftest.js gọi được mà không cần GUI, và probe assert được template mà không phải popup.
//
// Vì sao file này tồn tại: Electron KHÔNG tự dựng context menu như Chrome. Nó chỉ phát
// event `context-menu` rồi để app quyết dựng gì. Không có handler thì chuột phải vào ảnh
// trong chat không ra gì — đó là bug tính năng này sửa.
//
// Luật nhận diện ảnh phải nằm ĐÚNG MỘT CHỖ. Hai tầng cùng quyết: preload chặn menu của
// trang, main dựng menu của app. Lệch nhau là chuột phải CHẾT CÂM — trang bị bịt miệng mà
// app không thay thế. Xem plans/2026-08-24-copy-image/design.md.
'use strict'

// Chỉ ba scheme này tải lại được bằng downloadURL. `blob:` thì KHÔNG: URL đó chỉ có nghĩa
// trong renderer đã tạo nó, main gọi downloadURL sẽ im lặng không ra file nào. Disable mục
// menu còn thấy được, chứ bấm rồi không có gì xảy ra thì không ai biết vì sao.
const SAVABLE_PROTOCOLS = ['http:', 'https:', 'data:']

// Đuôi file theo mime. Cần vì URL fbcdn/zdn nhiều khi không có đuôi: đoán `.jpg` là sai với
// ảnh PNG, mà để trống đuôi thì Finder không biết mở bằng gì.
const MIME_EXT = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/heif': 'heif',
  'image/avif': 'avif',
  'image/svg+xml': 'svg',
  'image/bmp': 'bmp',
  'image/tiff': 'tiff',
  'image/x-icon': 'ico',
}

/** Mục menu có `enabled === false` là disable; thiếu field nghĩa là bật. */
const COPY_LABEL = 'Copy ảnh'
const SAVE_LABEL = 'Lưu ảnh…'

// Bỏ qua ảnh nhỏ hơn mức này: pixel theo dõi 1×1 và spacer nằm rải khắp trang Meta, nhận
// chúng làm "ảnh người dùng vừa trỏ vào" thì menu hiện ở những chỗ vô nghĩa.
const MIN_IMAGE_SIDE = 16

/**
 * Ảnh nằm DƯỚI điểm (x, y), kể cả khi bị element khác phủ lên.
 *
 * Vì sao cần: đo 2026-08-25 cho thấy Chromium chỉ trả `hasImageContents = true` khi không có
 * lớp phủ nào TỰ VẼ ra pixel. Lớp phủ nền đặc (kể cả `opacity: 0`) hoặc `<canvas>` đều làm
 * nó thành `false` — mà Meta phủ đúng kiểu đó lên ảnh trong app. Xem bảng đo trong
 * plans/2026-08-24-copy-image/design.md.
 *
 * BẮT BUỘC TỰ CHỨA — không tham chiếu bất cứ thứ gì ngoài tham số. Hàm này chạy ở HAI nơi:
 * gọi trực tiếp trong preload, và serialize bằng toString() để chạy trong trang qua
 * executeJavaScript. Tham chiếu ra module scope sẽ `undefined` ở nơi thứ hai và hỏng IM LẶNG
 * — selftest có một assert pin đúng điều này.
 *
 * @param {Document} doc
 * @param {number} minSide truyền tường minh, xem ghi chú tự chứa ở trên
 * @returns {string|null} `currentSrc` của ảnh, hoặc null
 */
function imageUnderPoint (doc, x, y, minSide) {
  const stack = doc.elementsFromPoint(x, y) || []
  for (let i = 0; i < stack.length; i++) {
    const el = stack[i]
    if (el.tagName !== 'IMG') continue
    const r = el.getBoundingClientRect()
    if (r.width < minSide || r.height < minSide) continue
    // `continue` chứ không `return null`: <img> chưa có src (placeholder lazy-load của Meta)
    // không được che mất ảnh thật nằm sâu hơn trong cùng chồng element.
    const src = el.currentSrc || el.src
    if (src) return src
  }
  return null
}

/**
 * Tắt `pointer-events` trên mọi element PHỦ LÊN ảnh tại (x, y), để hit-test của
 * `copyImageAt` nhìn thấy ảnh. Trả về hàm khôi phục qua `doc.__fbmessRestoreCovers`.
 *
 * Vì sao không copy bằng cách khác: `nativeImage.createFromBuffer` KHÔNG decode webp/gif (đo
 * 2026-08-25) mà Meta serve webp là chính; còn vẽ ảnh CDN ra canvas thì `toDataURL` ném
 * SecurityError vì canvas bị taint (ảnh không có CORS header). Đường duy nhất còn lại là
 * dùng chính decoder của Chromium — tức `copyImageAt` — nên phải làm cho hit-test của nó
 * chạm được tới ảnh.
 *
 * TỰ CHỨA như `imageUnderPoint` — cùng lý do, cùng assert trong selftest.
 */
function liftCoversAt (doc, x, y) {
  const stack = doc.elementsFromPoint(x, y) || []
  let at = -1
  for (let i = 0; i < stack.length; i++) {
    if (stack[i].tagName === 'IMG') { at = i; break }
  }
  // `at === 0` nghĩa là ảnh đã ở trên cùng, không có gì để tắt.
  if (at <= 0) return false
  const saved = []
  for (let i = 0; i < at; i++) {
    saved.push([stack[i], stack[i].style.pointerEvents])
    stack[i].style.pointerEvents = 'none'
  }
  const restore = () => {
    for (let i = 0; i < saved.length; i++) saved[i][0].style.pointerEvents = saved[i][1]
  }
  doc.__fbmessRestoreCovers = restore
  // Backstop: main chết hoặc mất kết nối giữa chừng thì trang vẫn phải bấm lại được. Không có
  // dòng này, một lỗi thoáng qua sẽ để lại vùng chat không click được cho tới khi reload.
  setTimeout(restore, 3000)
  return true
}

/** Câu lệnh khôi phục, dùng lại ở main. Gọi được nhiều lần, không có gì cũng không sao. */
const RESTORE_JS = 'document.__fbmessRestoreCovers && document.__fbmessRestoreCovers()'

/**
 * Có dựng menu của app không.
 *
 * `hasImageContents` là câu trả lời của chính Chromium cho "chỗ vừa bấm có phải ảnh có nội
 * dung không" — hit-test thật, không phải đoán từ DOM. Thiếu `srcURL` thì cả hai mục đều vô
 * nghĩa nên coi như không phải ảnh.
 */
function shouldShowImageMenu (params) {
  return !!(params && params.hasImageContents && params.srcURL)
}

/** Mục "Lưu ảnh…" có bấm được không. Xem SAVABLE_PROTOCOLS. */
function canSaveImage (srcURL) {
  if (!srcURL || typeof srcURL !== 'string') return false
  try { return SAVABLE_PROTOCOLS.includes(new URL(srcURL).protocol) } catch { return false }
}

/**
 * Template menu — mảng thuần, KHÔNG phải `Menu`.
 *
 * Tách khỏi main.js vì probe phải kiểm "menu ra đúng 2 mục" mà không được popup: popup cần
 * GUI session, trên máy build nó CHẶN process nên test treo thay vì fail. Treo tệ hơn fail —
 * CI đứng mãi mà không ai biết vì sao.
 *
 * @param {{srcURL?: string}} params `params` của event context-menu
 * @param {{onCopy?: Function, onSave?: Function}} [handlers]
 */
function imageMenuTemplate (params, handlers) {
  const h = handlers || {}
  return [
    { label: COPY_LABEL, click: h.onCopy },
    // Copy vẫn chạy với blob: — copyImageAt đọc bitmap đã decode trong renderer, không cần
    // tải lại URL. Chỉ mục save mới phụ thuộc scheme.
    { label: SAVE_LABEL, enabled: canSaveImage(params && params.srcURL), click: h.onSave },
  ]
}

/** Cắt về tên file thuần: bỏ query/hash, lấy segment cuối, dọn ký tự cấm của macOS. */
function baseName (s) {
  // Cắt query TRƯỚC khi tách segment: query của fbcdn chứa `/` (`?stp=dst-jpg/x`) nên tách
  // trước sẽ lấy ra một mảnh query làm tên file.
  let out = s.split('#')[0].split('?')[0]
  out = out.split(/[\\/]/).pop() || ''
  try { out = decodeURIComponent(out) } catch {}
  // Dọn SAU khi decode: `%2F` decode ra `/` thì lại thành ký tự cấm.
  //
  // Allowlist chứ không blocklist. Chữ (mọi hệ chữ, nên tên tiếng Việt còn nguyên), số, và
  // `._-()[]` cùng dấu cách được giữ; còn lại thành `_`. Blocklist ở đây từng phải liệt kê
  // `/` (cấm), `:` (Finder hiện thành `/`) và cả dải ký tự điều khiển — mà escape `\x00-\x1f`
  // viết trong source có ngày lọt vào file thành byte thật, không đọc ra được bằng mắt.
  return out.replace(/[^\p{L}\p{N}._\-()\[\] ]/gu, '_').trim()
}

/** Đuôi file suy từ mime. Rỗng nếu không suy được — KHÔNG đoán. */
function extFromMime (mimeType) {
  if (typeof mimeType !== 'string') return ''
  const mime = mimeType.split(';')[0].trim().toLowerCase()
  if (MIME_EXT[mime]) return MIME_EXT[mime]
  // Đường lùi cho định dạng mới (image/jxl…) mà bảng chưa biết. Chỉ subtype đơn giản.
  const m = /^image\/([a-z0-9]{1,5})$/.exec(mime)
  return m ? m[1] : ''
}

function hasExtension (base) {
  const dot = base.lastIndexOf('.')
  // `dot > 0` chứ không `>= 0`: `.hidden` là tên file ẩn, không phải đuôi.
  return dot > 0 && /^[a-z0-9]{1,5}$/i.test(base.slice(dot + 1))
}

/**
 * Tên file gợi ý cho Save panel.
 *
 * @param {string} name `DownloadItem.getFilename()` (hoặc một URL — hàm chịu cả hai)
 * @param {string} [mimeType] `DownloadItem.getMimeType()`, dùng khi tên không có đuôi
 */
function suggestedFilename (name, mimeType) {
  const raw = typeof name === 'string' ? name : ''
  // data: URL không mang tên file, mà payload base64 đầy `/` nên baseName() sẽ cắt ra một
  // mảnh base64 làm tên. Coi như không có tên.
  const base = /^data:/i.test(raw) ? '' : baseName(raw)
  const ext = extFromMime(mimeType)
  if (!base) return ext ? `image.${ext}` : 'image'
  if (hasExtension(base)) return base
  // Không đuôi và không suy được mime thì GIỮ NGUYÊN. Đoán sai đuôi tệ hơn thiếu đuôi:
  // file .jpg chứa PNG mở được ở Preview nhưng vỡ ở chỗ khác, và không ai nghi cái tên.
  return ext ? `${base}.${ext}` : base
}

module.exports = {
  COPY_LABEL, SAVE_LABEL, SAVABLE_PROTOCOLS, MIN_IMAGE_SIDE, RESTORE_JS,
  shouldShowImageMenu, canSaveImage, imageMenuTemplate, suggestedFilename,
  imageUnderPoint, liftCoversAt,
}
