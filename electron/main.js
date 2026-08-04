// FB Mess (Electron) — cùng UX với bản Swift: rail chọn kênh, ẩn chrome, link ngoài
// surface mở browser, tray resident, global hotkey, badge unread.
//
// Vì sao có bản này: WKWebView bùng 60–100% CPU theo đợt khiến nội dung đóng băng, trong
// khi Blink đo được 0.58% trung bình qua 14 giờ. Xem plans/2026-08-03-engine-swap/.
'use strict'

const {
  app, BrowserWindow, WebContentsView, Tray, Menu, globalShortcut, shell, session,
  nativeImage, ipcMain,
} = require('electron')
const path = require('path')
const fs = require('fs')
const { isInternal, isSurface, resolveServices, unreadFromTitle } = require('./services')

const RAIL_WIDTH = 68
const services = resolveServices(process.env.FBMESS_SERVICES)
const keepChrome = process.env.FBMESS_KEEP_FB_CHROME === '1'
const probe = process.argv.includes('--probe')
const probeOpened = []

let win = null
let railView = null
let tray = null
let activeIndex = 0
/** @type {{service: any, view: WebContentsView, unread: string|null}[]} */
const runtimes = []

function buildInfo () {
  try { return JSON.parse(fs.readFileSync(path.join(__dirname, 'build-info.json'), 'utf8')) }
  catch { return { commit: 'unknown', built: 'unknown' } }
}

if (process.argv.includes('--version')) {
  const b = buildInfo()
  console.log(`FB Mess (Electron) ${app.getVersion()} · build ${b.build ?? '?'}`)
  console.log(`commit   ${b.commit}${b.dirty ? ' (DIRTY)' : ''}`)
  console.log(`built    ${b.built}`)
  console.log(`electron ${process.versions.electron} · chromium ${process.versions.chrome}`)
  console.log(`services ${services.map(s => s.id).join('+')}`)
  app.quit()
  process.exit(0)
}

// Facebook sniff UA. UA mặc định của Electron có token `Electron/x.y` — bỏ đi để được
// serve đúng bundle như Chrome thật.
app.userAgentFallback = app.userAgentFallback
  .replace(/\sElectron\/[\d.]+/, '')
  .replace(new RegExp('\\s' + app.getName() + '\\/[\\d.]+'), '')

function layout () {
  if (!win) return
  const { width, height } = win.getContentBounds()
  const railW = services.length > 1 ? RAIL_WIDTH : 0
  if (railView) railView.setBounds({ x: 0, y: 0, width: railW, height })
  const rt = runtimes[activeIndex]
  if (rt) rt.view.setBounds({ x: railW, y: 0, width: Math.max(0, width - railW), height })
}

function pushRailState () {
  if (!railView) return
  const state = {
    active: activeIndex,
    items: runtimes.map(r => ({
      id: r.service.id, title: r.service.title, tint: r.service.tint, unread: r.unread,
    })),
  }
  railView.webContents.executeJavaScript(
    `window.render && window.render(${JSON.stringify(state)})`
  ).catch(() => {})
}

function updateBadge () {
  const rt = runtimes[activeIndex]
  const total = runtimes.reduce((n, r) => n + (r.unread ? parseInt(r.unread, 10) || 0 : 0), 0)
  if (app.dock) app.dock.setBadge(total > 0 ? String(total) : '')
  // Số cạnh icon menu bar — buildTray chạy sau createWindow nên tray có thể chưa tồn tại.
  if (tray) tray.setTitle(total > 0 ? ` ${total}` : '')
  if (win && rt) win.setTitle(rt.service.title + (rt.unread ? `  (${rt.unread})` : ''))
}

function makeServiceView (service) {
  const view = new WebContentsView({
    webPreferences: {
      partition: 'persist:fbmess',
      preload: path.join(__dirname, 'service-preload.js'),
      // sandbox:false để preload `require('./services')` được — khỏi nhân bản isSurface,
      // luật surface phải có một nguồn duy nhất.
      sandbox: false,
      additionalArguments: ['--fbmess-service=' + JSON.stringify({ surface: service.surface })],
    },
  })
  const wc = view.webContents

  wc.on('page-title-updated', (_e, title) => {
    const rt = runtimes.find(r => r.view === view)
    if (!rt) return
    rt.unread = unreadFromTitle(title)
    pushRailState()
    updateBadge()
  })

  wc.on('did-finish-load', async () => {
    if (keepChrome || !service.hideRules.length) return
    const sel = service.hideRules.map(([, s]) => s).join(',')
    try { await wc.insertCSS(sel + '{display:none!important}') } catch {}

    // Self-check 2 mốc, chỉ cảnh báo ở mốc sau: nav của Threads render trễ nên mốc sớm
    // luôn báo thiếu, mà cảnh báo luôn sai thì người ta quen bỏ qua cảnh báo thật.
    const check = async (phase) => {
      const js = `JSON.stringify(${JSON.stringify(service.hideRules)}.map(([n,s]) => n + '=' + document.querySelectorAll(s).length))`
      try {
        const hits = JSON.parse(await wc.executeJavaScript(js))
        const miss = hits.filter(h => h.endsWith('=0'))
        if (!miss.length) console.log(`[${service.id}] chrome(${phase}): ${hits.join(' ')}`)
        else if (phase === 'late') console.warn(`[${service.id}] CẢNH BÁO chrome: ${miss.join(',')} không khớp gì`)
      } catch {}
    }
    setTimeout(() => check('early'), 8000)
    setTimeout(() => check('late'), 25000)
  })

  // Link user click ngoài surface → browser. KHÔNG giữ trong app: link facebook.com trong
  // tin nhắn từng làm app rời khỏi Messenger và không có đường về.
  wc.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url)
    return { action: 'deny' }
  })
  // Backstop cho điều hướng KHÔNG do click (JS đặt location, meta refresh): chỉ chặn host
  // ngoài Meta. Host internal phải cho qua, nếu không thì chặn luôn luồng login.
  wc.on('will-navigate', (e, url) => {
    if (isInternal(url)) return
    e.preventDefault()
    shell.openExternal(url)
  })

  wc.loadURL(service.url)
  return view
}

function select (i) {
  if (i < 0 || i >= runtimes.length || !win) return
  const prev = runtimes[activeIndex]
  if (prev && prev.view !== runtimes[i].view) win.contentView.removeChildView(prev.view)
  activeIndex = i
  win.contentView.addChildView(runtimes[i].view)
  layout()
  pushRailState()
  updateBadge()
}

function createWindow () {
  win = new BrowserWindow({
    width: 1100, height: 760, minWidth: 420, minHeight: 400,
    title: 'FB Mess', show: false,
  })

  for (const s of services) {
    runtimes.push({ service: s, view: makeServiceView(s), unread: null })
  }

  if (services.length > 1) {
    railView = new WebContentsView({ webPreferences: { preload: path.join(__dirname, 'rail-preload.js') } })
    railView.webContents.loadFile(path.join(__dirname, 'rail.html'))
    win.contentView.addChildView(railView)
    railView.webContents.on('did-finish-load', pushRailState)
  }

  win.contentView.addChildView(runtimes[0].view)
  layout()
  win.on('resize', layout)
  win.show()

  // Đóng là ẩn, không quit — để lần mở sau tức thì, giống bản Swift.
  win.on('close', (e) => {
    if (!app.isQuitting) { e.preventDefault(); win.hide() }
  })
}

function toggleWindow () {
  if (!win) return
  if (win.isVisible() && win.isFocused()) win.hide()
  else { win.show(); win.focus() }
}

function buildTray () {
  // `✉` là ký tự text nên menu bar render nó nhỏ và xỉn. Dùng template image thật:
  // createFromPath tự lấy tray@2x.png cho màn Retina. Sinh lại bằng make-tray-icon.js.
  const icon = nativeImage.createFromPath(path.join(__dirname, 'tray.png'))
  icon.setTemplateImage(true)
  // Thiếu file trong asar thì createFromPath trả về ảnh rỗng, Tray im lặng hiện trống —
  // kiểu lỗi chỉ thấy ở bản đã package, không thấy khi chạy từ source.
  if (icon.isEmpty()) console.warn('CẢNH BÁO tray: tray.png rỗng hoặc thiếu trong bundle')
  else if (probe) console.log(`tray icon: ${JSON.stringify(icon.getSize())} template=${icon.isTemplateImage()}`)
  tray = new Tray(icon)
  const rebuild = () => {
    tray.setContextMenu(Menu.buildFromTemplate([
      ...runtimes.map((r, i) => ({
        label: r.service.title + (r.unread ? `  (${r.unread})` : ''),
        type: 'radio', checked: i === activeIndex,
        click: () => { select(i); win.show() },
      })),
      { type: 'separator' },
      { label: 'Hiện/ẩn cửa sổ', accelerator: 'Cmd+Shift+M', click: toggleWindow },
      { label: 'Tải lại', click: () => runtimes[activeIndex].view.webContents.reload() },
      { type: 'separator' },
      { label: 'Thoát', click: () => { app.isQuitting = true; app.quit() } },
    ]))
  }
  rebuild()
  updateBadge()
  setInterval(rebuild, 5000)
}

function buildMenu () {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: app.getName(),
      submenu: [
        ...runtimes.map((r, i) => ({
          label: r.service.title, accelerator: `Cmd+${i + 1}`, click: () => select(i),
        })),
        { type: 'separator' },
        { label: 'Về trang chính', accelerator: 'Cmd+Shift+H', click: () => runtimes[activeIndex].view.webContents.loadURL(runtimes[activeIndex].service.url) },
        { label: 'Quay lại', accelerator: 'Cmd+[', click: () => { const wc = runtimes[activeIndex].view.webContents; if (wc.navigationHistory.canGoBack()) wc.navigationHistory.goBack() } },
        { label: 'Tải lại', accelerator: 'Cmd+R', click: () => runtimes[activeIndex].view.webContents.reload() },
        { type: 'separator' },
        { label: 'Ẩn cửa sổ', accelerator: 'Cmd+W', click: () => win.hide() },
        { label: 'Thoát', accelerator: 'Cmd+Q', click: () => { app.isQuitting = true; app.quit() } },
      ],
    },
    { label: 'Sửa', submenu: [
      { role: 'undo' }, { role: 'redo' }, { type: 'separator' },
      { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' },
    ] },
  ]))
}

app.whenReady().then(() => {
  // Web Notification của trang — Electron hiện native, không cần shim như WKWebView.
  session.fromPartition('persist:fbmess').setPermissionRequestHandler((_wc, permission, cb) => {
    cb(permission === 'notifications' || permission === 'media')
  })

  ipcMain.on('rail:select', (_e, i) => select(i))
  // URL đến từ nội dung trang — không tin. shell.openExternal với scheme lạ là lỗ hổng.
  ipcMain.on('fbmess:open-external', (_e, url) => {
    if (!/^https?:\/\//i.test(url)) return
    if (probe) { probeOpened.push(url); return }
    shell.openExternal(url)
  })

  createWindow()
  buildMenu()
  buildTray()
  globalShortcut.register('Cmd+Shift+M', toggleWindow)

  app.on('activate', () => { if (win) win.show() })

  // Kiểm tra wiring không cần nhìn màn hình: `electron . --probe`. Cần cho máy build không
  // có GUI session — screencapture ở đây chỉ ra desktop trống nên không soi bằng mắt được.
  if (probe) setTimeout(async () => {
    const tiles = railView
      ? await railView.webContents.executeJavaScript('document.querySelectorAll(".tile").length')
      : 0
    console.log(`rail tiles: ${tiles} (kỳ vọng ${services.length})`)
    for (const r of runtimes) {
      const wc = r.view.webContents
      const login = await wc.executeJavaScript(
        '/log in|đăng nhập|mật khẩu|password/i.test(document.body ? document.body.innerText : "")'
      ).catch(() => null)
      console.log(`${r.service.id}: url=${wc.getURL()} title=${JSON.stringify(await wc.executeJavaScript('document.title'))} login=${login} unread=${r.unread}`)
    }
    // Link policy: click phải là tầng quyết định, không phải navigation. Test bằng click
    // tổng hợp trên chính trang đang load — chứng minh preload chạy trong ngữ cảnh thật.
    const wc = runtimes[0].view.webContents
    const clickOn = async (href) => {
      await wc.executeJavaScript(`(() => {
        const a = document.createElement('a')
        a.setAttribute('href', ${JSON.stringify('HREF')}.replace('HREF', ${JSON.stringify(href)}))
        a.textContent = 'x'; document.body.appendChild(a)
        a.addEventListener('click', e => e.preventDefault())
        a.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 }))
        a.remove()
      })()`)
      await new Promise(r => setTimeout(r, 300))
      return probeOpened.length
    }
    const before = probeOpened.length
    const afterExternal = await clickOn('https://example.com/')
    const afterSurface = await clickOn('/messages/t/1')
    console.log(`link ngoài  → openExternal: ${afterExternal > before ? 'CÓ (đúng)' : 'KHÔNG (SAI)'}`)
    console.log(`link surface → openExternal: ${afterSurface > afterExternal ? 'CÓ (SAI)' : 'KHÔNG (đúng)'}`)

    app.isQuitting = true
    app.quit()
  }, 25000)
})

app.on('before-quit', () => { app.isQuitting = true })
app.on('will-quit', () => globalShortcut.unregisterAll())
// KHÔNG quit khi đóng cửa sổ — app resident ở tray.
app.on('window-all-closed', () => {})
