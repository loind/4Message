// Chặn link ở tầng CLICK, không ở tầng navigation.
//
// Vì sao: `will-navigate` không phân biệt được click với redirect. Luồng login của Meta đi
// qua login.php / accounts/login — internal nhưng NGOÀI surface, nên nếu chặn theo
// navigation thì bấm "Log in" bị đẩy ra browser và không login được trong app. Bản Swift
// dùng `navigationType == .linkActivated`; Electron không có field đó, nên bắt click.
'use strict'
const { ipcRenderer } = require('electron')
const { isSurface } = require('./services')
const { imageUnderPoint, MIN_IMAGE_SIDE } = require('./image-menu')

const service = JSON.parse(
  (process.argv.find(a => a.startsWith('--fbmess-service=')) || '--fbmess-service={"surface":[]}')
    .slice('--fbmess-service='.length)
)

addEventListener('click', (e) => {
  if (e.defaultPrevented || e.button !== 0) return
  const a = e.target && e.target.closest && e.target.closest('a[href]')
  if (!a) return
  let url
  // href tương đối là bình thường (`/t/123`) — phải resolve theo location.
  try { url = new URL(a.getAttribute('href'), location.href) } catch { return }
  // `#`, `javascript:`, `mailto:` không phải điều hướng rời app — để trang tự xử.
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return
  if (isSurface(url.href, service)) return
  e.preventDefault()
  e.stopPropagation()
  ipcRenderer.send('fbmess:open-external', url.href)
}, true)

// Chuột phải vào ảnh: bịt menu riêng của trang để menu Copy ảnh / Lưu ảnh của app hiện lên.
//
// `stopPropagation` chứ KHÔNG `preventDefault`. preventDefault chính là thứ báo Chromium
// đừng dựng context menu — mà menu app cần chính là menu đó. stopPropagation chỉ khiến
// handler của trang không bao giờ nhìn thấy event, default behavior giữ nguyên nên
// `wc.on('context-menu')` bên main vẫn phát.
//
// Dùng CHUNG `imageUnderPoint` với main — không chép lại luật. Hai tầng lệch nhau là chuột
// phải chết câm: trang bị bịt miệng mà app không dựng gì thay thế. Ở đây preload dùng đúng
// hàm main sẽ chạy, nên không lệch được.
//
// KHÔNG dùng `e.target.tagName === 'IMG'`: Meta phủ element lên ảnh nên target thường là DIV
// trong khi ảnh vẫn nằm ngay dưới con trỏ — bản trước làm vậy và bỏ sót gần hết ảnh thật.
//
// Preload chạy trước script của trang nên listener này đăng ký trước; ở capture phase trên
// cùng một target, đăng ký trước thì chạy trước.
addEventListener('contextmenu', (e) => {
  if (imageUnderPoint(document, e.clientX, e.clientY, MIN_IMAGE_SIDE)) e.stopPropagation()
}, true)
