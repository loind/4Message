// Chặn link ở tầng CLICK, không ở tầng navigation.
//
// Vì sao: `will-navigate` không phân biệt được click với redirect. Luồng login của Meta đi
// qua login.php / accounts/login — internal nhưng NGOÀI surface, nên nếu chặn theo
// navigation thì bấm "Log in" bị đẩy ra browser và không login được trong app. Bản Swift
// dùng `navigationType == .linkActivated`; Electron không có field đó, nên bắt click.
'use strict'
const { ipcRenderer } = require('electron')
const { isSurface } = require('./services')

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
