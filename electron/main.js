// 4Message — cùng UX với bản Swift: rail chọn kênh, ẩn chrome, link ngoài
// surface mở browser, tray resident, global hotkey, badge unread.
//
// Vì sao có bản này: WKWebView bùng 60–100% CPU theo đợt khiến nội dung đóng băng, trong
// khi Blink đo được 0.58% trung bình qua 14 giờ. Xem plans/2026-08-03-engine-swap/.
'use strict'

const {
  app, BrowserWindow, WebContentsView, Tray, Menu, globalShortcut, shell, session,
  nativeImage, ipcMain, clipboard,
} = require('electron')
const path = require('path')
const fs = require('fs')
const {
  SERVICES, isInternal, isSurface, resolveServices, unreadFromTitle, messengerUnread,
  resolveEnabled, railVisible,
} = require('./services')
const {
  COPY_LABEL, SAVE_LABEL, MIN_IMAGE_SIDE, RESTORE_JS,
  shouldShowImageMenu, imageMenuTemplate, suggestedFilename,
  imageUnderPoint, liftCoversAt,
} = require('./image-menu')
const { loadPrefs, savePrefs } = require('./prefs')

const RAIL_WIDTH = 68
const services = resolveServices(process.env.FBMESS_SERVICES)
const keepChrome = process.env.FBMESS_KEEP_FB_CHROME === '1'
const probe = process.argv.includes('--probe')
const probeToggle = process.argv.includes('--probe-toggle')
const probeImage = process.argv.includes('--probe-image')
// Probe GHI prefs không được đụng userData thật: persist() ghi prefs.json, chạy test mà
// thiếu dòng này từng âm thầm ghi đè lựa chọn kênh thật của user. Cùng thư mục cố định cho
// cả ba — --probe-prefs (Task 6) phải đọc lại đúng cái --probe-toggle vừa ghi.
//
// --probe-image CỐ TÌNH KHÔNG có ở đây: nó phải chạy trên userData THẬT.
//
// Nửa giá trị nhất của mode đó là đo chuột phải trên ảnh CHAT thật, mà ảnh chat chỉ tồn tại
// khi đã đăng nhập — session đăng nhập nằm trong userData thật. Ném nó sang thư mục tạm thì
// mọi lần đo đều rơi vào trang login, và kết luận "ảnh bị phủ" rút ra từ đó nói về trang
// login chứ không về khung chat.
//
// An toàn vì mode này CHỈ ĐỌC: không gọi persist(), không savePrefs(). Xem README về việc
// phải thoát app đang chạy trước, tránh hai instance cùng khoá một profile Chromium.
if (probe || probeToggle || process.argv.includes('--probe-prefs')) {
  const probeDir = path.join(app.getPath('temp'), 'fbmess-probe')
  app.setPath('userData', probeDir)
  // --probe và --probe-toggle đều giả định xuất phát từ ĐỦ cả vũ trụ hiện tại: --probe assert
  // 'rail tiles' khớp services.length, --probe-toggle assert "đủ kênh để test" — prefs.json
  // rớt lại từ lần probe trước (vd --probe-toggle để lại 3/4 kênh) sẽ thu hẹp vũ trụ đó, làm
  // lần chạy sau fail oan chứ không phải vì bug thật. Chỉ reset phần TRONG vũ trụ hiện tại,
  // giữ nguyên id NGOÀI vũ trụ (cùng logic merge của persist()) — không thì test merge ở
  // Finding 3 tự phá chính dữ liệu nó cần kiểm tra.
  //
  // --probe-prefs KHÔNG được liệt ở đây: mode đó tồn tại để ĐỌC LẠI đúng cái đang có trên đĩa
  // (do --probe-toggle vừa ghi) — reset ở đây sẽ xoá luôn assertion duy nhất mà nó có.
  //
  // Hệ quả: thứ tự chạy 3 mode (3 lần gọi process riêng) BẮT BUỘC là --probe → --probe-toggle
  // → --probe-prefs, liên tiếp. Chèn --probe vào giữa --probe-toggle và --probe-prefs sẽ reset
  // lại prefs.json (về full universe, railCollapsed=false) khiến --probe-prefs fail oan 2 assert
  // 'kênh bật khớp prefs.json' và 'không dùng cả vũ trụ' — đọc y hệt một lỗi persistence thật.
  if (probe || probeToggle) {
    // Máy sạch chưa từng chạy probe thì probeDir chưa tồn tại — savePrefs ghi file tạm bên
    // trong đó nên cần thư mục có sẵn trước, không thì ENOENT văng ra TRƯỚC cả runProbe (ở
    // đây còn chưa kịp định nghĩa), Electron treo với dialog "App threw an error during load"
    // trong môi trường headless không ai bấm tắt được.
    fs.mkdirSync(probeDir, { recursive: true })
    // Reset thì chỉ hai mode kia — xem comment ở đầu khối về --probe-image.
    if (probe || probeToggle) {
      savePrefs(probeDir, { enabled: outsideUniverse(loadPrefs(probeDir).enabled), railCollapsed: false })
    }
  }
}
const probeOpened = []
/** Menu ảnh mà --probe-image ghi lại thay vì popup. @type {{service: string, srcURL: string, labels: string[], enabled: boolean[]}[]} */
const probeMenus = []
/** Mọi event context-menu --probe-image nhận được, KỂ CẢ cái bị shouldShowImageMenu loại. */
const probeRaw = []

let probeFailed = 0

/** Assert cho probe mode: in PASS/FAIL và đếm, để process exit code phản ánh kết quả. */
function check (label, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) probeFailed++
  console.log(`${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(actual)}${ok ? '' : ' — kỳ vọng ' + JSON.stringify(expected)}`)
}

/** Thoát với code khác 0 khi có assert fail — không thì CI coi như pass. */
function probeExit () {
  console.log(probeFailed ? `${probeFailed} assert FAIL` : 'tất cả assert PASS')
  app.isQuitting = true
  app.exit(probeFailed ? 1 : 0)
}

/**
 * Chạy một probe mode. MỌI probe phải đi qua đây, không tự gọi setTimeout.
 *
 * `finally` là phần quan trọng: throw trong async callback thành unhandled rejection,
 * probeExit() không bao giờ chạy, và process TREO vô hạn — phải kill -9. Test harness treo
 * tệ hơn test fail: CI đứng mãi mà không ai biết vì sao. Đã gặp thật khi activeId chưa tồn tại.
 */
function runProbe (delayMs, body) {
  setTimeout(async () => {
    try {
      await body()
    } catch (e) {
      probeFailed++
      console.log(`FAIL probe throw: ${(e && e.stack) || e}`)
    } finally {
      probeExit()
    }
  }, delayMs)
}

let win = null
let railView = null
let tray = null
// Danh tính kênh đang xem là `id`, KHÔNG phải index: runtimes[] co giãn khi bật/tắt kênh
// nên mọi index đang giữ đều lệch một cách im lặng.
let activeId = null

function active () { return runtimes.find(r => r.service.id === activeId) }
function activeIdx () { return runtimes.findIndex(r => r.service.id === activeId) }
/** @type {{service: any, view: WebContentsView, unread: string|null}[]} */
const runtimes = []

let railCollapsed = false

function enabledIds () { return runtimes.map(r => r.service.id) }

/**
 * Kênh nằm NGOÀI universe hiện tại trong một danh sách `enabled` đã lưu (hoặc `null`).
 * `null` = chưa chọn gì = mọi kênh đã biết đang bật — KHÔNG phải rỗng. Coi là rỗng thì lần
 * ghi đầu tiên dưới FBMESS_SERVICES thu hẹp sẽ xoá vĩnh viễn các kênh ngoài universe đó
 * (dùng chung cho persist() và reset đầu probe — hai chỗ này từng lệch nhau vì mỗi nơi tự
 * chép lại logic, một nơi quên xử lý `null`).
 */
function outsideUniverse (storedEnabled) {
  return (storedEnabled || SERVICES.map(s => s.id)).filter(id => !services.some(s => s.id === id))
}

function persist () {
  const dir = app.getPath('userData')
  // Giữ id nằm NGOÀI universe hiện tại: chạy với FBMESS_SERVICES thu hẹp không được
  // biến "universe bị thu hẹp để debug" thành "user đã tắt mấy kênh kia" vĩnh viễn.
  const outside = outsideUniverse(loadPrefs(dir).enabled)
  savePrefs(dir, { enabled: [...enabledIds(), ...outside], railCollapsed })
}

/** Vị trí canonical: đếm số kênh đang bật đứng trước `id` trong `services`. */
function canonicalSlot (id) {
  const rank = (sid) => services.findIndex(s => s.id === sid)
  return runtimes.filter(r => rank(r.service.id) < rank(id)).length
}

function setEnabled (id, on) {
  const svc = services.find(s => s.id === id)
  if (!svc || !win) return
  const at = runtimes.findIndex(r => r.service.id === id)
  if (on === (at >= 0)) return

  if (on) {
    runtimes.splice(canonicalSlot(id), 0, { service: svc, view: makeServiceView(svc), unread: null })
  } else {
    // Không cho tắt kênh cuối: cửa sổ rỗng không có đường thoát bằng chuột.
    if (runtimes.length <= 1) return
    const rt = runtimes[at]
    // Đổi active TRƯỚC khi hủy view, không thì active trỏ vào webContents đã chết.
    if (rt.service.id === activeId) {
      activeId = (runtimes[at + 1] || runtimes[at - 1]).service.id
    }
    win.contentView.removeChildView(rt.view)
    rt.view.webContents.close()
    runtimes.splice(at, 1)
  }

  persist()
  // selectId(activeId) đã tự chạy layout()/pushRailState()/updateBadge() — gọi lại ba hàm đó
  // ở đây là dư, mỗi lần bật/tắt kênh render rail hai lần cho một lần đổi.
  selectId(activeId)
  buildMenu()
}

function toggleRail () {
  railCollapsed = !railCollapsed
  persist()
  layout()
  buildMenu()
}

/** Item bật/tắt kênh, dùng chung cho app menu và tray menu. */
function serviceToggleItems () {
  const only = runtimes.length <= 1
  return services.map(s => {
    const on = runtimes.some(r => r.service.id === s.id)
    return {
      label: s.title, type: 'checkbox', checked: on,
      // Tắt kênh cuối cùng để lại cửa sổ rỗng — disable thay vì im lặng bỏ qua, để
      // người dùng thấy được vì sao không bấm được.
      enabled: !(on && only),
      // KHÔNG dùng `on` đã đóng closure ở đây: tray rebuild mỗi 5s (setInterval bên dưới),
      // nên bấm app-menu đổi trạng thái rồi bấm tray trong vòng 5s đó thấy `on` cũ — click
      // gọi setEnabled(id, !cũ) tức là bật lại đúng cái đã tắt, item coi như không phản ứng.
      // `checked`/`enabled` phía trên vẫn dùng giá trị lúc dựng menu — chỉ quyết định lúc
      // click mới cần đọc sống.
      click: () => setEnabled(s.id, !runtimes.some(r => r.service.id === s.id)),
    }
  })
}

function buildInfo () {
  try { return JSON.parse(fs.readFileSync(path.join(__dirname, 'build-info.json'), 'utf8')) }
  catch { return { commit: 'unknown', built: 'unknown' } }
}

if (process.argv.includes('--version')) {
  const b = buildInfo()
  console.log(`${app.getName()} ${app.getVersion()} · build ${b.build ?? '?'}`)
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
  const railW = railVisible(runtimes.length, railCollapsed) ? RAIL_WIDTH : 0
  if (railView) railView.setBounds({ x: 0, y: 0, width: railW, height })
  const rt = active()
  if (rt) rt.view.setBounds({ x: railW, y: 0, width: Math.max(0, width - railW), height })
}

function pushRailState () {
  if (!railView) return
  const state = {
    active: activeIdx(),
    items: runtimes.map(r => ({
      id: r.service.id, title: r.service.title, tint: r.service.tint, unread: r.unread,
    })),
  }
  railView.webContents.executeJavaScript(
    `window.render && window.render(${JSON.stringify(state)})`
  ).catch(() => {})
}

function updateBadge () {
  const rt = active()
  const total = runtimes.reduce((n, r) => n + (r.unread ? parseInt(r.unread, 10) || 0 : 0), 0)
  if (app.dock) app.dock.setBadge(total > 0 ? String(total) : '')
  // Số cạnh icon menu bar — buildTray chạy sau createWindow nên tray có thể chưa tồn tại.
  if (tray) tray.setTitle(total > 0 ? ` ${total}` : '')
  if (win && rt) win.setTitle(rt.service.title + (rt.unread ? `  (${rt.unread})` : ''))
}

/**
 * Copy ảnh vào clipboard.
 *
 * `native === true`: Chromium đã nhận ra ảnh, copyImageAt chạy thẳng.
 *
 * `native === false`: ảnh bị lớp phủ che. Nhấc pointer-events của lớp phủ → copyImageAt →
 * trả lại. Đo 2026-08-25: cách này khôi phục hit-test trong CẢ BỐN kiểu lớp phủ chặn được
 * (nền đặc, opacity:0, canvas, và nền đặc có text).
 *
 * KHÔNG dùng net.fetch + nativeImage: nativeImage không decode webp/gif, mà Meta serve webp
 * là chính. KHÔNG dùng canvas.toDataURL: canvas bị taint vì ảnh CDN không có CORS header.
 * Cả hai đều đã đo và đều chết, xem design doc.
 */
async function copyImageAtPoint (wc, x, y, native) {
  if (native) { wc.copyImageAt(x, y); return }
  let lifted = false
  try {
    lifted = await wc.executeJavaScript(`(${liftCoversAt})(document, ${x}, ${y})`)
    wc.copyImageAt(x, y)
    // Hit-test của copyImageAt chạy TRONG renderer và không đồng bộ với lời gọi này. Trả
    // pointer-events lại ngay lập tức là đua với chính nó — ảnh vừa lộ ra đã bị che lại
    // trước khi hit-test kịp chạm tới, và Copy im lặng không có gì. Chờ một nhịp.
    await new Promise(r => setTimeout(r, 400))
  } catch (e) {
    console.warn(`copy ảnh lỗi: ${(e && e.message) || e}`)
  } finally {
    // Bắt buộc chạy kể cả khi trên có throw: bỏ sót là để lại vùng chat không bấm được cho
    // tới lúc reload. liftCoversAt còn một setTimeout backstop nữa cho ca main chết hẳn.
    if (lifted) wc.executeJavaScript(RESTORE_JS).catch(() => {})
  }
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
    rt.unread = service.unreadRule === 'facebook'
      ? messengerUnread(title, rt.unread)
      : unreadFromTitle(title)
    pushRailState()
    updateBadge()
  })

  wc.on('did-finish-load', async () => {
    if (keepChrome || !service.hideRules.length) return
    const sel = service.hideRules.map(([, s]) => s).join(',')
    try { await wc.insertCSS(sel + '{display:none!important}') } catch {}

    // Self-check 2 mốc, chỉ cảnh báo ở mốc sau: nav của Threads render trễ nên mốc sớm
    // luôn báo thiếu, mà cảnh báo luôn sai thì người ta quen bỏ qua cảnh báo thật.
    // Tên riêng (không phải `check`) — trùng tên với assert của probe là cái bẫy cho lần sửa
    // sau: shadow biến ngoài closure, lỗi chỉ lộ khi chạy probe chứ không lộ lúc đọc code.
    const checkChrome = async (phase) => {
      const js = `JSON.stringify(${JSON.stringify(service.hideRules)}.map(([n,s]) => n + '=' + document.querySelectorAll(s).length))`
      try {
        const hits = JSON.parse(await wc.executeJavaScript(js))
        const miss = hits.filter(h => h.endsWith('=0'))
        if (!miss.length) console.log(`[${service.id}] chrome(${phase}): ${hits.join(' ')}`)
        else if (phase === 'late') console.warn(`[${service.id}] CẢNH BÁO chrome: ${miss.join(',')} không khớp gì`)
      } catch {}
    }
    setTimeout(() => checkChrome('early'), 8000)
    setTimeout(() => checkChrome('late'), 25000)
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

  // Chuột phải vào ảnh → Copy ảnh / Lưu ảnh. Electron KHÔNG tự dựng context menu như Chrome:
  // nó chỉ phát event rồi để app quyết, nên thiếu handler này thì chuột phải không ra gì.
  //
  // `copyImageAt` nhận toạ độ thẳng từ `params` nên không phải quy đổi qua zoom factor —
  // đó là lý do giữ trigger ở main thay vì gửi clientX/clientY từ preload qua IPC.
  wc.on('context-menu', async (_e, params) => {
    // Ghi TRƯỚC mọi cổng lọc: khi menu không hiện, thứ cần biết là Chromium đã trả về gì.
    // Không có dòng này thì "không ra menu" chỉ là một sự im lặng, không tra được.
    if (probeImage) {
      probeRaw.push({
        service: service.id,
        mediaType: params.mediaType,
        hasImageContents: params.hasImageContents,
        srcURL: (params.srcURL || '').slice(0, 60),
      })
    }

    // Hai đường tới cùng một menu:
    //   native — Chromium tự nhận ra ảnh. Copy dùng thẳng copyImageAt.
    //   fallback — ảnh bị lớp phủ che (Meta làm suốt), phải hỏi DOM và nhấc lớp phủ lúc copy.
    // Xem bảng đo "cái gì chặn hit-test" trong plans/2026-08-24-copy-image/design.md.
    const native = shouldShowImageMenu(params)
    const srcURL = native
      ? params.srcURL
      : await wc.executeJavaScript(
        `(${imageUnderPoint})(document, ${params.x}, ${params.y}, ${MIN_IMAGE_SIDE})`
      ).catch(() => null)
    if (!srcURL) return

    const template = imageMenuTemplate({ srcURL }, {
      onCopy: () => copyImageAtPoint(wc, params.x, params.y, native),
      onSave: () => wc.downloadURL(srcURL),
    })
    // popup() cần GUI session: trên máy build nó CHẶN process nên test treo thay vì fail, mà
    // treo tệ hơn fail — CI đứng mãi không ai biết vì sao. Probe chỉ ghi lại rồi return.
    if (probeImage) {
      probeMenus.push({
        service: service.id,
        srcURL,
        native,
        copy: template[0].click,
        labels: template.map(i => i.label),
        enabled: template.map(i => i.enabled !== false),
      })
      return
    }
    Menu.buildFromTemplate(template).popup({ window: win })
  })

  wc.loadURL(service.url)
  return view
}

function selectId (id) {
  const next = runtimes.find(r => r.service.id === id)
  if (!next || !win) return
  const prev = active()
  if (prev && prev !== next) win.contentView.removeChildView(prev.view)
  activeId = id
  win.contentView.addChildView(next.view)
  layout()
  pushRailState()
  updateBadge()
}

function createWindow () {
  win = new BrowserWindow({
    width: 1100, height: 760, minWidth: 420, minHeight: 400,
    title: app.getName(), show: false,
  })

  const prefs = loadPrefs(app.getPath('userData'))
  railCollapsed = prefs.railCollapsed
  // Chỉ dựng view cho kênh đang bật — kênh tắt không tạo view rồi hủy.
  for (const s of resolveEnabled(services, prefs)) {
    runtimes.push({ service: s, view: makeServiceView(s), unread: null })
  }

  // Rail dựng khi vũ trụ có nhiều hơn 1 kênh, còn hiện hay không thì layout() quyết —
  // vì số kênh bật đổi được lúc chạy, không thể quyết một lần lúc khởi động.
  if (services.length > 1) {
    railView = new WebContentsView({ webPreferences: { preload: path.join(__dirname, 'rail-preload.js') } })
    railView.webContents.loadFile(path.join(__dirname, 'rail.html'))
    win.contentView.addChildView(railView)
    railView.webContents.on('did-finish-load', pushRailState)
  }

  activeId = runtimes[0].service.id
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
        type: 'radio', checked: r.service.id === activeId,
        click: () => { selectId(r.service.id); win.show() },
      })),
      { type: 'separator' },
      { label: 'Kênh', submenu: serviceToggleItems() },
      { label: railCollapsed ? 'Hiện cột kênh' : 'Ẩn cột kênh', enabled: runtimes.length > 1, click: toggleRail },
      { type: 'separator' },
      { label: 'Hiện/ẩn cửa sổ', accelerator: 'Cmd+Shift+M', click: toggleWindow },
      { label: 'Tải lại', click: () => active().view.webContents.reload() },
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
          label: r.service.title, accelerator: `Cmd+${i + 1}`,
          click: () => selectId(r.service.id),
        })),
        { type: 'separator' },
        { label: 'Về trang chính', accelerator: 'Cmd+Shift+H', click: () => active().view.webContents.loadURL(active().service.url) },
        { label: 'Quay lại', accelerator: 'Cmd+[', click: () => { const wc = active().view.webContents; if (wc.navigationHistory.canGoBack()) wc.navigationHistory.goBack() } },
        { label: 'Tải lại', accelerator: 'Cmd+R', click: () => active().view.webContents.reload() },
        { type: 'separator' },
        { label: 'Ẩn cửa sổ', accelerator: 'Cmd+W', click: () => win.hide() },
        { label: 'Thoát', accelerator: 'Cmd+Q', click: () => { app.isQuitting = true; app.quit() } },
      ],
    },
    {
      label: 'Kênh',
      submenu: [
        ...serviceToggleItems(),
        { type: 'separator' },
        {
          label: railCollapsed ? 'Hiện cột kênh' : 'Ẩn cột kênh',
          accelerator: 'Cmd+0',
          enabled: runtimes.length > 1,
          click: toggleRail,
        },
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
  //
  // Gate theo ORIGIN, không chỉ theo loại quyền: partition này chỉ nên có content của Meta
  // và Zalo, nhưng một redirect hay iframe đưa host lạ vào đó thì nó cũng xin được
  // camera/mic. Fail-closed — origin không đọc được thì từ chối.
  const ses = session.fromPartition('persist:fbmess')
  ses.setPermissionRequestHandler((_wc, permission, cb, details) => {
    const wanted = permission === 'notifications' || permission === 'media'
    const origin = (details && (details.requestingUrl || details.securityOrigin)) || ''
    const ok = wanted && isInternal(origin)
    // Log khi từ chối: nếu Electron đổi tên field details, notification sẽ chết im lặng —
    // mà đó là tính năng cốt lõi của app. Có dòng log này thì còn tra được.
    if (wanted && !ok) console.warn(`quyền BỊ TỪ CHỐI: ${permission} từ ${origin || '(không rõ origin)'}`)
    cb(ok)
  })

  // "Lưu ảnh…": Electron chỉ hiện Save panel khi savePath CHƯA set — chỗ này không set nó,
  // chỉ đặt thư mục và tên file mặc định. downloadURL chạy trong đúng session này nên cookie
  // fbcdn/zdn đi kèm sẵn; đó là lý do không tự tải bytes bằng net.request.
  //
  // Áp cho MỌI download của session, không lọc theo URL: app hiện không có đường download
  // nào khác nên không có gì để lọc, và nếu sau này có thì "vào Downloads, tên đã chuẩn hoá"
  // vẫn là hành vi muốn có. Ghi ra đây để lần sau khỏi tưởng là thiếu guard.
  ses.on('will-download', (e, item) => {
    // Save panel là modal — ở probe nó treo test chứ không fail. Huỷ luôn download.
    if (probeImage || probe) { e.preventDefault(); return }
    item.setSaveDialogOptions({
      defaultPath: path.join(
        app.getPath('downloads'),
        suggestedFilename(item.getFilename(), item.getMimeType())
      ),
    })
  })

  // Rail gửi vị trí tile; đổi ngay sang id vì index chỉ đúng tại thời điểm render.
  ipcMain.on('rail:select', (_e, i) => {
    const rt = runtimes[i]
    if (rt) selectId(rt.service.id)
  })
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
  if (probe) runProbe(25000, async () => {
    const tiles = railView
      ? await railView.webContents.executeJavaScript('document.querySelectorAll(".tile").length')
      : 0
    check('rail tiles', tiles, services.length)
    check('activeId', activeId, services[0].id)
    for (const r of runtimes) {
      const wc = r.view.webContents
      const login = await wc.executeJavaScript(
        '/log in|đăng nhập|mật khẩu|password/i.test(document.body ? document.body.innerText : "")'
      ).catch(() => null)
      console.log(`${r.service.id}: url=${wc.getURL()} title=${JSON.stringify(await wc.executeJavaScript('document.title'))} login=${login} unread=${r.unread}`)
    }
    // Link policy: click phải là tầng quyết định, không phải navigation. Test bằng click
    // tổng hợp trên chính trang đang load — chứng minh preload chạy trong ngữ cảnh thật.
    const wc = active().view.webContents
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

  })

  if (process.argv.includes('--probe-toggle')) runProbe(20000, async () => {
    const pids = new Map(runtimes.map(r => [r.service.id, r.view.webContents.getOSProcessId()]))
    console.log(`bật ${runtimes.length} kênh: ${[...pids.entries()].map(([k, v]) => k + '=' + v).join(' ')}`)

    // Precondition: universe 1 kênh thì vòng lặp tắt bên dưới không có gì để tắt, leaked
    // rỗng so rỗng PASS vô nghĩa — đúng lúc phải chứng minh process thật sự chết.
    check('universe đủ để test tắt kênh', services.length >= 2, true)

    // Precondition: nếu prefs.json (kể cả của chính probe trước đó) để lại ít hơn đủ kênh,
    // vòng lặp tắt bên dưới không tắt gì và assert liveness PASS rỗng-so-rỗng một cách vô
    // nghĩa — đúng lúc nó phải chứng minh process thật sự chết.
    check('đủ kênh để test', pids.size, services.length)

    // --- Kịch bản nguy hiểm nhất của setEnabled: tắt ĐÚNG kênh đang xem ---
    // activeId lúc khởi động luôn là runtimes[0].service.id (gán trong createWindow). Vòng
    // lặp "tắt tất cả trừ keep" bên dưới cố tình không đụng runtimes[0], nên nếu thiếu đoạn
    // này thì nhánh `if (rt.service.id === activeId)` trong setEnabled — đổi activeId sang
    // láng giềng TRƯỚC khi removeChildView/close() view — không bao giờ chạy trong cả bộ
    // test. Đây đúng là lỗ hổng bản trước của probe này mắc phải: `keep` và `activeId` khi
    // đó cùng là runtimes[0], nên so `keep === keep` không thể fail dù thứ tự có bị đảo.
    const activeAtStart = activeId
    const activeAtStartPid = pids.get(activeAtStart)
    const survivorExpected = runtimes[1].service.id
    setEnabled(activeAtStart, false)

    check('kênh đang xem biến mất khỏi runtimes sau khi tắt', runtimes.some(r => r.service.id === activeAtStart), false)
    check('activeId chuyển sang láng giềng còn sống', activeId, survivorExpected)
    // Nếu setEnabled lỡ destroy view TRƯỚC khi reassign activeId, active() ở đây sẽ trỏ vào
    // webContents vừa .close() (hoặc vào runtime đã bị splice mất) — isDestroyed() bắt được
    // ngay tại chỗ, không cần đợi 3s để process OS chết mới biết.
    check('active() còn dùng được ngay sau khi tắt kênh đang xem', active().view.webContents.isDestroyed(), false)

    // Trả về đúng trạng thái ban đầu — phần còn lại của bộ test bên dưới giả định runtimes[0]
    // là kênh sống sót cuối cùng, nên không phải viết lại các assert đã có.
    setEnabled(activeAtStart, true)
    selectId(activeAtStart)
    check('activeId quay lại kênh gốc sau khi bật lại', activeId, activeAtStart)

    const keep = runtimes[0].service.id
    for (const id of [...pids.keys()].filter(x => x !== keep)) setEnabled(id, false)
    // Process chết không đồng bộ với close() — chờ rồi mới kiểm liveness.
    await new Promise(r => setTimeout(r, 3000))

    check('còn bật', runtimes.length, 1)
    check('activeId không đổi vì kênh bị tắt trong vòng lặp trên không phải kênh đang xem', activeId, keep)

    // Điều kiện MẠNH NHẤT của thiết kế: process renderer của kênh tắt phải CHẾT.
    // Process chết là RAM đã trả về OS — khác với đo footprint, nơi bmalloc trả page chậm
    // và từng làm số liệu bản WKWebView vô nghĩa.
    const alive = (pid) => { try { process.kill(pid, 0); return true } catch { return false } }
    const leaked = [...pids.entries()].filter(([id, pid]) => id !== keep && alive(pid)).map(([id]) => id)
    check('process kênh đã tắt còn sống', leaked, [])
    // Process GỐC của kênh vừa tắt-lúc-đang-xem-rồi-bật-lại ở trên: bật lại tạo process MỚI,
    // process CŨ phải bị OS thu hồi y như mọi kênh tắt khác, không phải vì nó là activeId.
    check('process gốc của kênh vừa tắt lúc đang xem còn sống', alive(activeAtStartPid), false)

    check('rail hiện khi còn 1 kênh', railVisible(runtimes.length, railCollapsed), false)

    // Tắt kênh cuối cùng phải là no-op: cửa sổ rỗng không có đường thoát bằng chuột.
    setEnabled(keep, false)
    check('còn bật sau khi thử tắt kênh cuối', runtimes.length, 1)

    if (services.length >= 4) {
      // Bật lại phải vào đúng vị trí canonical. Bật services[3] TRƯỚC services[1] để chứng
      // minh chèn giữa — nếu chỉ append thì thứ tự sẽ là [0],[3],[1] và assert này fail.
      setEnabled(services[3].id, true)
      setEnabled(services[1].id, true)
      check('thứ tự canonical sau khi bật lại',
        runtimes.map(r => r.service.id),
        [services[0].id, services[1].id, services[3].id])
    } else {
      // services[3]/services[1] đánh index tuyệt đối — universe hẹp hơn 4 kênh (vd chạy với
      // FBMESS_SERVICES thu hẹp để debug) sẽ .id trên undefined và văng exception thay vì
      // FAIL có ý nghĩa. Bỏ qua và NÓI RA, không thì coverage bị thu hẹp âm thầm trông như
      // full coverage.
      console.log(`bỏ qua check thứ tự canonical: universe chỉ ${services.length} kênh, cần >= 4`)
    }

    // ⌘0 phải độc lập với quy tắc "còn 1 kênh": 3 kênh bật mà ẩn tay thì rail vẫn phải ẩn.
    // Đó là toàn bộ lý do có hai trạng thái tách rời.
    toggleRail()
    check('ẩn tay: railCollapsed', railCollapsed, true)
    check('ẩn tay: rail hiện', railVisible(runtimes.length, railCollapsed), false)
    toggleRail()
    check('hiện lại: railCollapsed', railCollapsed, false)
    check('hiện lại: rail hiện', railVisible(runtimes.length, railCollapsed), true)

    const kenh = Menu.getApplicationMenu().items.find(i => i.label === 'Kênh')
    check('có menu Kênh', !!kenh, true)
    // 4 kênh + separator + ẩn/hiện cột
    check('số item menu Kênh', kenh.submenu.items.length, services.length + 2)
    check('kênh đang tick',
      kenh.submenu.items.filter(i => i.type === 'checkbox' && i.checked).map(i => i.label).sort(),
      runtimes.map(r => r.service.title).sort())
    check('nhãn ẩn/hiện cột', kenh.submenu.items[services.length + 1].label, 'Ẩn cột kênh')

    // Mục ẩn/hiện cột kênh trên TRAY dùng chung guard `enabled: runtimes.length > 1` với item
    // này ở app-menu (fix round 1 — tray thiếu guard, đã thêm vào buildTray()). Không đọc lại
    // được item thật trên tray để assert trực tiếp: Electron Tray không có getContextMenu()
    // (xác nhận qua electron.d.ts và probe thủ công tạo Tray + setContextMenu rồi liệt kê
    // prototype — không có getter nào). Đọc lại item app-menu (đọc được thật) làm bằng chứng
    // guard đúng — chạy thêm với FBMESS_SERVICES=messenger để thấy nhánh false.
    check('app-menu ẩn/hiện cột: enabled khớp runtimes.length > 1',
      kenh.submenu.items[services.length + 1].enabled, runtimes.length > 1)

    // Để lại railCollapsed=true trước khi ghi prefs: hai lần toggle ở trên đưa nó về false
    // (== default), nên nếu --probe-prefs so railCollapsed với prefs.json mà cả hai đều là
    // default false thì assert PASS dù loadPrefs không hề được đọc — false so false không
    // chứng minh được gì. Thêm một lần toggle nữa để prefs.json mang giá trị KHÁC default.
    toggleRail()
    check('railCollapsed=true trước khi ghi prefs', railCollapsed, true)

    persist()
  })

  // Menu ảnh. Tách ASSERT khỏi BÁO CÁO là cố ý:
  //
  //   - Cơ chế Chromium → Electron (chuột phải ra params.hasImageContents, preload bịt được
  //     menu của trang) là deterministic, không cần login → assert được, chạy trên máy build.
  //   - Messenger/Zalo có phủ <div> trong suốt lên ảnh chat hay không thì CHỈ máy đã login
  //     mới trả lời được. Biến nó thành assert là để probe fail oan trên máy build — đúng cái
  //     bẫy đã ghi ở checkChrome(): cảnh báo luôn sai thì người ta quen bỏ qua cảnh báo thật.
  //
  // Mode này không đọc cũng không ghi prefs nên KHÔNG dính ràng buộc thứ tự của ba mode kia.
  if (probeImage) runProbe(20000, async () => {
    const IMG_X = 40, IMG_Y = 40, IMG_W = 240, IMG_H = 180
    // PNG 1×1 trong suốt. data: URL nên không cần mạng, không cần login, và savable được
    // (khác blob:) — đủ để assert cả hai mục menu ở trạng thái bật.
    const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    // 100×100 cho ca bị phủ: kích thước clipboard là assert, mà 1×1 thì "không rỗng" gần như
    // không chứng minh được gì.
    const PNG100 = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGQAAABkCAYAAABw4pVUAAAAPElEQVR42u3OMQEAAAgDoJnc6BpjDyQgd2XAYDAYDAaDwWAwGAwGg8FgMBgMBoPBYDAYDAaDwWAwGAyGjy0Vy1/lWtHZbAAAAABJRU5ErkJggg=='

    /**
     * Chuột phải thật qua sendInputEvent, KHÔNG phải dispatchEvent.
     *
     * Khác hẳn ca link policy ở --probe: chỗ đó preload nghe DOM event nên MouseEvent tổng
     * hợp là đủ. Event `context-menu` của Electron thì sinh từ đường input thật của browser —
     * dispatchEvent(new MouseEvent('contextmenu')) không bao giờ chạm tới nó.
     */
    const rightClickAt = async (wc, x, y) => {
      probeMenus.length = 0
      probeRaw.length = 0
      await wc.executeJavaScript('window.__probePageSawContextMenu = false').catch(() => {})
      wc.sendInputEvent({ type: 'mouseDown', x, y, button: 'right', clickCount: 1 })
      wc.sendInputEvent({ type: 'mouseUp', x, y, button: 'right', clickCount: 1 })
      await new Promise(r => setTimeout(r, 500))
      return {
        menu: probeMenus[probeMenus.length - 1] || null,
        raw: probeRaw[probeRaw.length - 1] || null,
        pageSaw: await wc.executeJavaScript('window.__probePageSawContextMenu').catch(() => null),
      }
    }

    // --- ASSERT: cơ chế, không cần login ---
    //
    // Chạy trên view RIÊNG ghim vào trang tĩnh, KHÔNG dùng view của kênh. Cùng
    // `webPreferences` với view kênh nên vẫn kiểm đúng cặp preload ↔ main.
    //
    // Vì sao không dùng thẳng view kênh: máy CHƯA đăng nhập thì Messenger nhảy redirect liên
    // tục (login.php → index.php → …). Mỗi lần điều hướng là một renderer mới, nên <img> vừa
    // chèn biến mất và `sendInputEvent` bắn vào widget đã chết — KHÔNG có event context-menu
    // nào tới nơi và cả 11 assert FAIL cùng lúc. Đo 2026-10-10: ghim trang tĩnh thì 15/15
    // PASS, không đổi một dòng code tính năng nào.
    //
    // Đây đúng là điều khối này tự nhận: "cơ chế, không cần login". Dính vào trang thật thì
    // nó phụ thuộc mạng và trạng thái đăng nhập — tức là fail oan trên máy build, đúng cái
    // bẫy đã ghi ở checkChrome().
    // Dựng qua `makeServiceView` chứ KHÔNG `new WebContentsView` tay: handler
    // `wc.on('context-menu')` — thứ đang được kiểm — nằm trong đó. Dựng tay thì preload vẫn
    // bịt menu của trang mà main không dựng gì thay thế, và mọi assert về menu FAIL vì thiếu
    // handler chứ không phải vì tính năng hỏng.
    const probeView = makeServiceView(active().service)
    win.contentView.addChildView(probeView)
    probeView.setBounds({ x: 0, y: 0, width: 800, height: 600 })
    const wc = probeView.webContents
    await wc.loadURL('data:text/html,<body style="background:#eee"></body>')
    await wc.executeJavaScript(`(() => {
      window.__probePageSawContextMenu = false
      // Listener của TRANG (main world). Preload chặn ở capture phase trên window nên listener
      // này không được thấy event khi bấm trúng ảnh — đó chính là hợp đồng cần chứng minh.
      document.addEventListener('contextmenu', () => { window.__probePageSawContextMenu = true })
      const img = document.createElement('img')
      img.id = '__probe_img'
      img.src = ${JSON.stringify(PNG)}
      img.style.cssText = 'position:fixed;left:${IMG_X}px;top:${IMG_Y}px;width:${IMG_W}px;height:${IMG_H}px;z-index:2147483647'
      document.body.appendChild(img)
      const plain = document.createElement('div')
      plain.id = '__probe_plain'
      plain.style.cssText = 'position:fixed;left:${IMG_X}px;top:${IMG_Y + IMG_H + 20}px;width:${IMG_W}px;height:80px;z-index:2147483647;background:#808080'
      document.body.appendChild(plain)
    })()`)
    // Ảnh data: decode đồng bộ hay không là chuyện của Blink — chờ một nhịp cho chắc, không
    // thì hasImageContents về false vì ảnh chưa có nội dung và assert fail oan.
    await new Promise(r => setTimeout(r, 500))

    const onImage = await rightClickAt(wc, IMG_X + IMG_W / 2, IMG_Y + IMG_H / 2)
    check('chuột phải vào ảnh: có dựng menu', !!onImage.menu, true)
    check('menu đúng 2 mục', onImage.menu && onImage.menu.labels, [COPY_LABEL, SAVE_LABEL])
    check('cả 2 mục bấm được với data: URL', onImage.menu && onImage.menu.enabled, [true, true])
    // srcURL khớp chứng minh luôn cả không gian toạ độ: sai hệ quy chiếu thì đã bấm ra ngoài
    // ảnh (rail rộng 68px là mức lệch dễ gặp nhất) và không có menu nào để so.
    check('menu trỏ đúng ảnh vừa bấm', onImage.menu && onImage.menu.srcURL, PNG)
    check('trang KHÔNG thấy contextmenu trên ảnh', onImage.pageSaw, false)

    const onPlain = await rightClickAt(wc, IMG_X + IMG_W / 2, IMG_Y + IMG_H + 60)
    check('chuột phải ngoài ảnh: KHÔNG dựng menu', !!onPlain.menu, false)
    // Nửa còn lại của hợp đồng "để trang tự xử". Thiếu assert này thì một preload chặn SẠCH
    // mọi contextmenu vẫn PASS hết các assert trên.
    check('trang VẪN thấy contextmenu ngoài ảnh', onPlain.pageSaw, true)

    // --- ASSERT 2: ảnh BỊ LỚP PHỦ CHE — đúng ca thật của Meta ---
    // Lớp phủ nền ĐẶC: đo 2026-08-25 cho thấy nền trong suốt KHÔNG chặn hit-test, chỉ lớp
    // phủ tự vẽ ra pixel mới chặn. Dùng nền trong suốt ở đây thì test PASS mà không hề chạm
    // vào đường fallback — tức là không kiểm gì cả.
    //
    // Dọn ảnh của ca 1 TRƯỚC: nó nằm cùng toạ độ, nên còn để đó thì imageUnderPoint bắt trúng
    // nó và cả khối assert dưới đây đo nhầm ảnh (PASS/FAIL đều vô nghĩa).
    await wc.executeJavaScript(
      `for (const id of ['__probe_img', '__probe_plain']) { const el = document.getElementById(id); if (el) el.remove() }`
    ).catch(() => {})
    await wc.executeJavaScript(`(() => {
      const img = document.createElement('img')
      img.id = '__probe_img2'
      img.src = ${JSON.stringify(PNG100)}
      img.style.cssText = 'position:fixed;left:${IMG_X}px;top:${IMG_Y}px;width:${IMG_W}px;height:${IMG_H}px;z-index:2147483646'
      document.body.appendChild(img)
      const cover = document.createElement('div')
      cover.id = '__probe_cover'
      cover.style.cssText = 'position:fixed;left:${IMG_X}px;top:${IMG_Y}px;width:${IMG_W}px;height:${IMG_H}px;z-index:2147483647;background:#123456'
      document.body.appendChild(cover)
    })()`)
    await new Promise(r => setTimeout(r, 500))

    const covered = await rightClickAt(wc, IMG_X + IMG_W / 2, IMG_Y + IMG_H / 2)
    // Precondition: nếu lớp phủ không thật sự chặn thì mọi assert dưới đây đo đường native,
    // và đường fallback — thứ cần kiểm — không chạy dòng nào.
    check('ảnh bị phủ: Chromium KHÔNG tự nhận ra', covered.raw && covered.raw.hasImageContents, false)
    check('ảnh bị phủ: vẫn dựng được menu', !!covered.menu, true)
    check('ảnh bị phủ: đi đường fallback', covered.menu && covered.menu.native, false)
    check('ảnh bị phủ: menu trỏ đúng ảnh', covered.menu && covered.menu.srcURL, PNG100)
    check('ảnh bị phủ: trang KHÔNG thấy contextmenu', covered.pageSaw, false)

    // Điều kiện MẠNH NHẤT: copy phải ra bitmap thật trong clipboard. Menu hiện đủ 2 mục mà
    // bấm không ra gì là dạng hỏng khó chịu nhất — nhìn thì thấy tính năng có tồn tại.
    clipboard.clear()
    if (covered.menu) await covered.menu.copy()
    const copied = clipboard.readImage()
    check('ảnh bị phủ: copy ra bitmap trong clipboard', !copied.isEmpty(), true)
    check('ảnh bị phủ: đúng kích thước ảnh gốc', copied.isEmpty() ? null : copied.getSize(), { width: 100, height: 100 })

    await new Promise(r => setTimeout(r, 300))
    // Trả lại pointer-events là bắt buộc: bỏ sót thì vùng chat không bấm được cho tới lúc
    // reload — hỏng nặng hơn nhiều so với việc copy không chạy.
    check('ảnh bị phủ: pointer-events đã trả lại',
      await wc.executeJavaScript(`document.getElementById('__probe_cover').style.pointerEvents`), '')

    await wc.executeJavaScript(
      `for (const id of ['__probe_img', '__probe_plain', '__probe_img2', '__probe_cover']) { const el = document.getElementById(id); if (el) el.remove() }`
    ).catch(() => {})

    win.contentView.removeChildView(probeView)

    // --- BÁO CÁO: ảnh thật của trang, cần login mới có ảnh chat ---
    console.log('--- đo trên ảnh thật (không assert: cần login mới có ảnh chat) ---')
    console.log(`userData: ${app.getPath('userData')}`)
    for (const rt of runtimes) {
      selectId(rt.service.id)
      const w = rt.view.webContents
      // sendInputEvent CHỈ tới nơi khi cửa sổ chứa view đang focused (ràng buộc của Electron)
      // VÀ view vừa chọn là view đang focus trong cửa sổ đó. Chạy probe từ terminal thì
      // terminal mới là app frontmost, nên phải cướp focus — steal:true.
      //
      // Thiếu đoạn này, mọi kênh sau kênh đầu tiên báo "không nhận được event nào": đọc y hệt
      // một lỗi thật của tính năng, trong khi thực ra là input chưa bao giờ tới nơi.
      app.focus({ steal: true })
      win.show()
      win.focus()
      w.focus()
      await new Promise(r => setTimeout(r, 800))
      const focused = await w.executeJavaScript('document.hasFocus()').catch(() => null)
      if (!focused) console.log(`[${rt.service.id}] CẢNH BÁO: view không focus được — số đo dưới đây không tin được`)
      const box = await w.executeJavaScript(`(() => {
        let best = null
        for (const el of document.querySelectorAll('img')) {
          const r = el.getBoundingClientRect()
          if (r.width < 40 || r.height < 40) continue
          const cx = r.left + r.width / 2
          const cy = r.top + r.height / 2
          // TÂM phải nằm trong viewport, không chỉ mép trên-trái. Ảnh cao thò khỏi mép dưới
          // có tâm ở ngoài màn: sendInputEvent tới đó là bấm vào hư không, Chromium trả
          // mediaType=none và số đo đọc thành "ảnh không nhận diện được" — sai hoàn toàn.
          if (cx < 0 || cy < 0 || cx >= innerWidth || cy >= innerHeight) continue
          if (!best || r.width * r.height > best.w * best.h) {
            best = { x: cx, y: cy, w: r.width, h: r.height,
                     src: (el.currentSrc || el.src || '').slice(0, 70) }
          }
        }
        if (!best) return null
        // Ai NẰM TRÊN ở đúng toạ độ sắp bấm. Đây là câu trả lời trực tiếp cho giả thuyết
        // "div trong suốt phủ lên ảnh": hitTag khác IMG nghĩa là chuột phải không bao giờ
        // chạm tới <img>, và cả preload lẫn hasImageContents đều đúng khi nói "không phải ảnh".
        const hit = document.elementFromPoint(best.x, best.y)
        best.hitTag = hit ? hit.tagName : '(không có)'
        // Cả chồng element tại điểm bấm, theo thứ tự trên→dưới. Nếu <IMG> nằm đâu đó trong
        // chồng mà không ở trên cùng thì phương án "dò xuống chồng element" trong preload là
        // đường cứu được ca ảnh bị phủ — đo luôn ở đây để khỏi phải đoán lúc quyết định.
        const stack = document.elementsFromPoint(best.x, best.y) || []
        best.stack = stack.slice(0, 8).map(el => el.tagName).join('>')
        best.imgInStack = stack.some(el => el.tagName === 'IMG')
        // Ảnh KHÔNG có mặt trong chồng element dù điểm bấm nằm trong rect của nó = nó bị đặt
        // pointer-events:none. elementsFromPoint bỏ qua những element như vậy, nên luật "dò
        // chồng element" mù hoàn toàn với ca này.
        for (const el of document.querySelectorAll('img')) {
          const r = el.getBoundingClientRect()
          if (Math.abs(r.left + r.width / 2 - best.x) < 1 && Math.abs(r.top + r.height / 2 - best.y) < 1) {
            best.imgPointerEvents = getComputedStyle(el).pointerEvents
            break
          }
        }
        best.complete = (() => {
          for (const el of document.querySelectorAll('img')) {
            const r = el.getBoundingClientRect()
            if (Math.abs(r.left + r.width / 2 - best.x) < 1 && Math.abs(r.top + r.height / 2 - best.y) < 1) {
              return el.complete && el.naturalWidth > 0
            }
          }
          return null
        })()
        return best
      })()`).catch(() => null)
      // Chưa login thì mọi số đo bên dưới nói về TRANG LOGIN chứ không về khung chat — mà
      // câu hỏi cần trả lời là về ảnh chat. In ra để không ai rút kết luận từ nhầm trang.
      const login = await w.executeJavaScript(
        '/log in|đăng nhập|mật khẩu|password/i.test(document.body ? document.body.innerText : "")'
      ).catch(() => null)
      if (login !== false) console.log(`[${rt.service.id}] CẢNH BÁO: trông như CHƯA đăng nhập (login=${login}) — số đo dưới đây nói về trang login`)
      if (!box) {
        console.log(`[${rt.service.id}] không có <img> nào >= 40px với tâm trong viewport`)
        continue
      }
      const hit = await rightClickAt(w, box.x, box.y)
      const raw = hit.raw
        ? `mediaType=${hit.raw.mediaType} hasImageContents=${hit.raw.hasImageContents}`
        : 'KHÔNG nhận được event context-menu nào'
      console.log(`[${rt.service.id}] ảnh ${Math.round(box.w)}×${Math.round(box.h)} decoded=${box.complete} · img-trong-chồng=${box.imgInStack} pointer-events=${box.imgPointerEvents} · chồng: ${box.stack}`)
      console.log(`             → menu: ${hit.menu ? 'CÓ' : 'KHÔNG'} · ${raw} · src=${box.src}`)
    }
    console.log('Đọc kết quả: <IMG> ở "trên cùng" mà menu vẫn KHÔNG → luật nhận diện sai, sửa code.')
    console.log('Tag khác IMG → ảnh bị phủ, xem mục Rủi ro trong plans/2026-08-24-copy-image/design.md.')
  })

  if (process.argv.includes('--probe-prefs')) runProbe(15000, () => {
    // Kỳ vọng đọc từ prefs.json mà --probe-toggle vừa ghi, KHÔNG hardcode: test này chứng
    // minh loadPrefs được nối vào createWindow, nên phải so với file trên đĩa.
    const saved = loadPrefs(app.getPath('userData'))
    check('kênh bật khớp prefs.json', enabledIds(), saved.enabled)
    check('railCollapsed khớp prefs.json', railCollapsed, saved.railCollapsed)
    check('không dùng cả vũ trụ', enabledIds().length < services.length, true)
  })
})

app.on('before-quit', () => { app.isQuitting = true })
app.on('will-quit', () => globalShortcut.unregisterAll())
// KHÔNG quit khi đóng cửa sổ — app resident ở tray.
app.on('window-all-closed', () => {})
