// Shell Electron tối giản: chỉ để đo CPU layout của Blink trên cùng trang Messenger,
// so với WKWebView. KHÔNG port tính năng (rail, hotkey, badge, notification shim) — chúng
// không ảnh hưởng chi phí layout, mà đây là biến duy nhất cần đo.
//
//   npm start                      # facebook.com/messages
//   PROBE_URL=... npm start
//   PROBE_KEEP_CHROME=1 npm start  # không inject CSS ẩn chrome
//
// In ra PID của renderer bằng `getOSProcessId()` — chính xác, khỏi phải đoán qua pgrep.
// Đo Chrome bằng pgrep đã từng nhầm sang renderer của Bitwarden và Orca.

const { app, BrowserWindow } = require('electron')

const URL_TO_LOAD = process.env.PROBE_URL || 'https://www.facebook.com/messages/'

// Cùng rule với Service "messenger" trong Sources/Messenger/Services.swift, để so
// apples-to-apples với app WKWebView.
const HIDE_RULES = process.env.PROBE_KEEP_CHROME === '1' ? [] : [
  '[role="navigation"]:has(a[href^="/marketplace/"])',
  'input[aria-label="Search Facebook"]',
  '*:has(> input[aria-label="Search Facebook"])',
  '[role="button"][aria-label="Exit typeahead"]',
  '[role="button"][aria-label="Facebook menu"]',
]

// Facebook sniff UA. UA mặc định của Electron có token `Electron/x.y` — bỏ đi để nó serve
// đúng bundle như Chrome thật, nếu không thì ta đo một biến thể khác chứ không phải Blink
// trên cùng trang.
app.userAgentFallback = app.userAgentFallback
  .replace(/\sElectron\/[\d.]+/, '')
  .replace(/\sfbmess-electron-probe\/[\d.]+/, '')

function createWindow () {
  const win = new BrowserWindow({
    width: 1100,
    height: 760,
    title: 'Electron probe',
    webPreferences: {
      // Session bền để login một lần là xong, giống WKWebsiteDataStore của app.
      partition: 'persist:fbmess-probe',
    },
  })

  win.loadURL(URL_TO_LOAD)

  win.webContents.on('did-finish-load', async () => {
    if (HIDE_RULES.length) {
      await win.webContents.insertCSS(HIDE_RULES.join(',') + '{display:none!important}')
    }
    const title = await win.webContents.executeJavaScript('document.title')
    const probe = await win.webContents.executeJavaScript(`
      JSON.stringify({
        threadLinks: document.querySelectorAll('a[href*="/t/"]').length,
        rows: document.querySelectorAll('[role="row"]').length,
        login: /log in|đăng nhập|password|mật khẩu/i.test(document.body ? document.body.innerText : ''),
      })
    `)
    console.log('[probe] url        :', win.webContents.getURL())
    console.log('[probe] title      :', title)
    console.log('[probe] state      :', probe)
    console.log('[probe] renderer   :', win.webContents.getOSProcessId())
    console.log('[probe] ua         :', app.userAgentFallback)
    console.log('[probe] hide rules :', HIDE_RULES.length)
  })
}

app.whenReady().then(createWindow)
app.on('window-all-closed', () => app.quit())
