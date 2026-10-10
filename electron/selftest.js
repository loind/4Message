// Check logic thuần, không cần GUI/mạng/login — build-electron.sh gọi làm cổng build.
// Chỉ giữ những case đã từng sai thật, không test getter.
const assert = require('assert')
const { isInternal, isSurface, resolveServices, unreadFromTitle, messengerUnread, SERVICES } = require('./services')

const messenger = SERVICES.find(s => s.id === 'messenger')
const threads = SERVICES.find(s => s.id === 'threads')
const zalo = SERVICES.find(s => s.id === 'zalo')

// pathPrefix gắn với host: facebook.com chỉ /messages là chat, messenger.com cả domain.
assert.ok(isSurface('https://www.facebook.com/messages/t/123', messenger))
assert.ok(isSurface('https://www.messenger.com/t/123', messenger))
assert.ok(!isSurface('https://www.facebook.com/marketplace/', messenger))
// Lỗi từng mắc: link facebook.com trong tin nhắn chiếm cửa sổ, không có đường về.
assert.ok(!isSurface('https://www.facebook.com/some.page', messenger))
// Prefix phải khớp trọn segment, không thì /messagesfake lọt.
assert.ok(!isSurface('https://www.facebook.com/messagesfake', messenger))
// Threads = feed + DM: cả domain ở lại trong app, DM ở /messages/ (không phải /direct/).
assert.strictEqual(new URL(threads.url).pathname, '/')
assert.ok(isSurface('https://www.threads.com/messages/', threads))
assert.ok(isSurface('https://www.threads.com/', threads))
// Từng bị đẩy ra browser vì pathPrefix /messages — xem feed thì phải ở lại trong app.
assert.ok(isSurface('https://www.threads.com/@x/post/1', threads))
assert.ok(isSurface('https://www.threads.com/search', threads))
assert.ok(!isSurface('https://evil-threads.com/', threads))
assert.strictEqual(threads.hideRules.length, 0)

// Zalo: service đầu tiên ngoài Meta. Login chuyển sang id.zalo.me nên host đó là surface;
// zalo.me (profile, bài viết công khai) thì KHÔNG — giữ trong app là lặp bug facebook.com.
assert.ok(isSurface('https://chat.zalo.me/', zalo))
assert.ok(isSurface('https://id.zalo.me/account?continue=x', zalo))
assert.ok(!isSurface('https://zalo.me/abc', zalo))
assert.ok(!isSurface('https://chat.zalo.me.evil.com/', zalo))
assert.ok(!isSurface('https://chat.zalo.me/', messenger))
assert.strictEqual(zalo.hideRules.length, 0)

// isInternal rộng hơn isSurface — luồng login redirect qua nhiều domain của Meta.
assert.ok(isInternal('https://static.xx.fbcdn.net/x.js'))
assert.ok(!isInternal('https://example.com/'))
// Tránh bẫy endsWith: notfacebook.com KHÔNG phải facebook.com.
assert.ok(!isInternal('https://notfacebook.com/'))
// CDN của Zalo: thiếu là captcha và avatar không load (đo bằng probe).
assert.ok(isInternal('https://stc-chat.zdn.vn/x.js'))
assert.ok(isInternal('https://s120-ava-talk.zadn.vn/a.jpg'))
assert.ok(isInternal('https://id.zalo.me/account'))
assert.ok(!isInternal('https://notzalo.me/'))

assert.strictEqual(unreadFromTitle('(3) Chats · Messenger'), '3')
assert.strictEqual(unreadFromTitle('(9+) Instagram'), '9+')
assert.strictEqual(unreadFromTitle('Messenger'), null)
assert.strictEqual(unreadFromTitle('(hi) x'), null)

// Badge trên surface facebook.com. Title dưới đây giữ nguyên ĐỊNH DẠNG quan sát được trong
// log đo 2026-08-07 (chỉ thay tên người bằng tên giả — log thật chứa PII, không đưa vào
// repo). Định dạng mới là thứ hàm dựa vào, không phải nội dung tên.
//
// `(N)` chỉ đếm TIN NHẮN. b73 từng trừ số chuông thông báo khỏi đây và badge ra âm rồi
// biến mất trong khi vẫn còn tin chưa đọc — regression đắt nhất của tính năng này.
assert.strictEqual(messengerUnread('(3) Messenger | Facebook', null), '3')
assert.strictEqual(messengerUnread('(1) Messenger | Facebook', null), '1')
// Title flash 2 giây/lần: không mang số, phải GIỮ badge — đọc thành 0 là bug chớp tắt.
assert.strictEqual(messengerUnread('Minh messaged you', '2'), '2')
assert.strictEqual(messengerUnread('Lan messaged Nhóm bạn thân', '2'), '2')
// Nhưng title nghỉ mới là bằng chứng đã đọc hết — nhận nhầm thì badge kẹt số cũ vĩnh viễn.
assert.strictEqual(messengerUnread('Messenger | Facebook', '2'), null)
assert.strictEqual(messengerUnread('Messenger', '2'), null)
// prev chưa có gì thì flash cũng không dựng badge từ hư không.
assert.strictEqual(messengerUnread('Minh messaged you', null), null)
assert.strictEqual(messengerUnread('(9+) Messenger | Facebook', null), '9+')

assert.deepStrictEqual(resolveServices('threads,messenger').map(s => s.id), ['threads', 'messenger'])
assert.deepStrictEqual(resolveServices('nope').map(s => s.id), SERVICES.map(s => s.id))
assert.deepStrictEqual(resolveServices('threads,threads').map(s => s.id), ['threads'])

// Glyph rail nằm ở rail.html chứ không ở services.js, nên thêm service mà quên glyph là
// lỗi im lặng: tile hiện ra màu trơn không hình. Đây là cổng chặn.
const rail = require('fs').readFileSync(require('path').join(__dirname, 'rail.html'), 'utf8')
for (const s of SERVICES) {
  assert.ok(rail.includes(`${s.id}: '`), `thiếu glyph rail cho service: ${s.id}`)
}

const { resolveEnabled, railVisible } = require('./services')

const ALL = SERVICES
const ids = (list) => list.map(s => s.id)

// Thứ tự rail phải canonical, KHÔNG theo thứ tự người dùng bấm bật.
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: ['zalo', 'messenger'] })), ['messenger', 'zalo'])
// Không bao giờ 0 kênh — cửa sổ rỗng là trạng thái không có đường thoát bằng chuột.
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: [] })), ids(ALL))
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: ['nope'] })), ids(ALL))
assert.deepStrictEqual(ids(resolveEnabled(ALL, {})), ids(ALL))
// prefs.json là file người dùng sửa được bằng tay → kiểu sai phải không làm sập.
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: 'messenger' })), ids(ALL))
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: [null, 3] })), ids(ALL))
// Id ngoài vũ trụ FBMESS_SERVICES bị bỏ.
const TWO = resolveServices('messenger,instagram')
assert.deepStrictEqual(ids(resolveEnabled(TWO, { enabled: ['zalo'] })), ids(TWO))
assert.deepStrictEqual(ids(resolveEnabled(TWO, { enabled: ['instagram'] })), ['instagram'])
// Trùng lặp không sinh tile trùng.
assert.deepStrictEqual(ids(resolveEnabled(ALL, { enabled: ['zalo', 'zalo'] })), ['zalo'])

assert.strictEqual(railVisible(1, false), false)
assert.strictEqual(railVisible(2, false), true)
assert.strictEqual(railVisible(2, true), false)
assert.strictEqual(railVisible(1, true), false)

const {
  COPY_LABEL, SAVE_LABEL, MIN_IMAGE_SIDE, shouldShowImageMenu, canSaveImage, imageMenuTemplate,
  suggestedFilename, imageUnderPoint, liftCoversAt,
} = require('./image-menu')

// Menu chỉ dựng khi chính Chromium xác nhận chỗ bấm là ảnh CÓ nội dung — hit-test thật,
// không đoán từ DOM.
assert.ok(shouldShowImageMenu({ hasImageContents: true, srcURL: 'https://x/a.jpg' }))
assert.ok(!shouldShowImageMenu({ hasImageContents: false, srcURL: 'https://x/a.jpg' }))
// srcURL rỗng thì cả hai mục đều vô nghĩa.
assert.ok(!shouldShowImageMenu({ hasImageContents: true, srcURL: '' }))
assert.ok(!shouldShowImageMenu({}))
assert.ok(!shouldShowImageMenu(null))

// blob: chỉ có nghĩa trong renderer đã tạo nó — main gọi downloadURL sẽ im lặng không ra file.
assert.ok(!canSaveImage('blob:https://www.messenger.com/8f1e-0000'))
assert.ok(canSaveImage('https://scontent.xx.fbcdn.net/v/t1/1_2_3_n.jpg'))
assert.ok(canSaveImage('data:image/png;base64,iVBORw0KGgo='))
assert.ok(!canSaveImage('file:///etc/passwd'))
assert.ok(!canSaveImage(''))
assert.ok(!canSaveImage(undefined))

// Menu LUÔN 2 mục, kể cả blob: — mục save DISABLE chứ không biến mất. Mục bấm được rồi im
// lặng không có gì xảy ra mới là thứ không ai lần ra được nguyên nhân.
const blobMenu = imageMenuTemplate({ srcURL: 'blob:https://x/1' })
assert.deepStrictEqual(blobMenu.map(i => i.label), [COPY_LABEL, SAVE_LABEL])
assert.strictEqual(blobMenu[1].enabled, false)
assert.strictEqual(imageMenuTemplate({ srcURL: 'https://x/a.jpg' })[1].enabled, true)
// Handler nối đúng mục — đảo hai cái là bug im lặng, menu vẫn hiện đủ 2 dòng.
let copied = 0
let saved = 0
const wired = imageMenuTemplate({ srcURL: 'https://x/a.jpg' }, { onCopy: () => copied++, onSave: () => saved++ })
wired[0].click()
wired[1].click()
assert.deepStrictEqual([copied, saved], [1, 1])

// Query của fbcdn dài và chứa cả `/` — phải cắt query TRƯỚC khi tách segment, không thì tên
// file thành một mảnh query.
assert.strictEqual(suggestedFilename('123_456_n.jpg?stp=dst-jpg_p526x296/x&_nc_cat=1'), '123_456_n.jpg')
assert.strictEqual(suggestedFilename('https://scontent.xx.fbcdn.net/v/t1.15752-9/a.png'), 'a.png')
// Không đuôi → suy từ mime. Đoán .jpg cho ảnh PNG là bug không ai nghi tới cái tên file.
assert.strictEqual(suggestedFilename('abc123', 'image/png'), 'abc123.png')
assert.strictEqual(suggestedFilename('abc123', 'image/jpeg'), 'abc123.jpg')
assert.strictEqual(suggestedFilename('abc123', 'image/webp; charset=binary'), 'abc123.webp')
// Định dạng bảng chưa biết vẫn suy được từ subtype.
assert.strictEqual(suggestedFilename('abc123', 'image/jxl'), 'abc123.jxl')
// Không đuôi và không suy được mime thì GIỮ NGUYÊN, KHÔNG đoán.
assert.strictEqual(suggestedFilename('abc123'), 'abc123')
assert.strictEqual(suggestedFilename('abc123', 'application/octet-stream'), 'abc123')
// Có đuôi rồi thì mime không được đè lên.
assert.strictEqual(suggestedFilename('a.gif', 'image/png'), 'a.gif')
// data: URL không mang tên file, mà payload base64 đầy `/` nên tách segment ra rác base64.
assert.strictEqual(suggestedFilename('data:image/png;base64,iVBORw0KGgo/AAAA', 'image/png'), 'image.png')
assert.strictEqual(suggestedFilename('', 'image/webp'), 'image.webp')
assert.strictEqual(suggestedFilename(''), 'image')
assert.strictEqual(suggestedFilename(null), 'image')
// `/` là ký tự cấm; `%2F` decode xong lại thành nó, nên phải dọn SAU khi decode.
assert.strictEqual(suggestedFilename('a%2Fb.jpg'), 'a_b.jpg')
// `:` bị Finder hiển thị thành `/`.
assert.ok(!suggestedFilename('x%3Ay.jpg').includes(':'))
// Allowlist theo \p{L} chứ không phải \w — tên tiếng Việt phải còn nguyên cả dấu lẫn dấu cách.
assert.strictEqual(suggestedFilename('ảnh nhóm.jpg'), 'ảnh nhóm.jpg')
// `.hidden` là tên file ẩn, không phải đuôi file.
assert.strictEqual(suggestedFilename('.hidden', 'image/png'), '.hidden.png')

// --- Tìm ảnh dưới con trỏ, kể cả khi bị phủ ---

/** DOM giả đủ dùng cho imageUnderPoint/liftCoversAt — không cần Electron, không cần trang. */
// `style.pointerEvents` trả CHUỖI RỖNG khi element không có inline style — không phải
// undefined. Mô hình sai chỗ này thì test khôi phục sẽ pass với giá trị `undefined`, mà gán
// `undefined` vào style thật lại ra chuỗi "undefined" và khoá luôn pointer-events.
const el = (tagName, w, h, src) => ({
  tagName,
  currentSrc: src,
  style: { pointerEvents: '' },
  getBoundingClientRect: () => ({ width: w, height: h }),
})
const docOf = (...stack) => ({ elementsFromPoint: () => stack })

// Ca thường: ảnh ở trên cùng.
assert.strictEqual(imageUnderPoint(docOf(el('IMG', 74, 74, 'https://x/a.webp')), 1, 1, MIN_IMAGE_SIDE), 'https://x/a.webp')
// Ca THẬT của Meta: ảnh nằm tận đáy chồng element (đo 2026-08-25, Instagram: 5 DIV phủ lên).
assert.strictEqual(
  imageUnderPoint(docOf(el('DIV', 9, 9), el('DIV', 9, 9), el('DIV', 9, 9), el('IMG', 74, 74, 'https://x/b.webp')), 1, 1, MIN_IMAGE_SIDE),
  'https://x/b.webp')
// Không có ảnh nào → null, để menu không hiện và trang tự xử.
assert.strictEqual(imageUnderPoint(docOf(el('DIV', 50, 50), el('SPAN', 50, 50)), 1, 1, MIN_IMAGE_SIDE), null)
assert.strictEqual(imageUnderPoint(docOf(), 1, 1, MIN_IMAGE_SIDE), null)
// Pixel theo dõi 1×1 và spacer nhỏ không được tính là ảnh người dùng trỏ vào.
assert.strictEqual(imageUnderPoint(docOf(el('IMG', 1, 1, 'https://x/track.gif')), 1, 1, MIN_IMAGE_SIDE), null)
// Ảnh nhỏ đứng trước không được che mất ảnh thật đứng sau.
assert.strictEqual(
  imageUnderPoint(docOf(el('IMG', 1, 1, 'https://x/track.gif'), el('IMG', 200, 200, 'https://x/real.jpg')), 1, 1, MIN_IMAGE_SIDE),
  'https://x/real.jpg')
// <img> chưa có src (placeholder lazy-load) không được che mất ảnh thật nằm sâu hơn.
assert.strictEqual(
  imageUnderPoint(docOf(el('IMG', 200, 200, undefined), el('IMG', 200, 200, 'https://x/real.jpg')), 1, 1, MIN_IMAGE_SIDE),
  'https://x/real.jpg')

// Nhấc lớp phủ: chỉ đụng element NẰM TRÊN ảnh, và trả lại đúng giá trị cũ (kể cả giá trị
// trang tự đặt sẵn) — ghi đè vĩnh viễn pointer-events của trang là phá layout người khác.
const cover1 = el('DIV', 50, 50)
const cover2 = el('DIV', 50, 50)
cover2.style.pointerEvents = 'auto'
const pic = el('IMG', 200, 200, 'https://x/c.jpg')
const under = el('DIV', 50, 50)
const doc = docOf(cover1, cover2, pic, under)
assert.strictEqual(liftCoversAt(doc, 1, 1), true)
assert.strictEqual(cover1.style.pointerEvents, 'none')
assert.strictEqual(cover2.style.pointerEvents, 'none')
// Element DƯỚI ảnh không liên quan, không được đụng tới.
assert.strictEqual(under.style.pointerEvents, '')
doc.__fbmessRestoreCovers()
assert.strictEqual(cover1.style.pointerEvents, '')
assert.strictEqual(cover2.style.pointerEvents, 'auto')
// Ảnh đã ở trên cùng thì không có gì để nhấc — main dùng giá trị này để bỏ qua bước khôi phục.
assert.strictEqual(liftCoversAt(docOf(el('IMG', 200, 200, 'https://x/d.jpg')), 1, 1), false)
assert.strictEqual(liftCoversAt(docOf(el('DIV', 50, 50)), 1, 1), false)

// CỔNG CHẶN: hai hàm trên chạy ở HAI nơi — gọi trực tiếp trong preload, và serialize bằng
// toString() để chạy trong trang qua executeJavaScript. Tham chiếu ra module scope sẽ
// `undefined` ở nơi thứ hai và hỏng IM LẶNG (menu không bao giờ hiện trên ảnh bị phủ, không
// có lỗi nào in ra). Danh sách dưới đây là mọi tên ở module scope của image-menu.js.
for (const fn of [imageUnderPoint, liftCoversAt]) {
  const src = fn.toString()
  for (const name of ['MIN_IMAGE_SIDE', 'SAVABLE_PROTOCOLS', 'MIME_EXT', 'COPY_LABEL',
    'SAVE_LABEL', 'RESTORE_JS', 'baseName', 'extFromMime', 'hasExtension', 'canSaveImage']) {
    assert.ok(!new RegExp('\\b' + name + '\\b').test(src),
      `${fn.name} phải tự chứa: đang tham chiếu ${name} ở module scope, sẽ undefined khi chạy trong trang`)
  }
}

const os = require('os')
const fs = require('fs')
const path = require('path')
const { loadPrefs, savePrefs } = require('./prefs')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fbmess-prefs-'))

// Chưa có file → mặc định. enabled=null nghĩa "chưa chọn", khác [] nghĩa "chọn rỗng".
assert.deepStrictEqual(loadPrefs(dir), { enabled: null, railCollapsed: false })

// File rác không được làm sập app.
fs.writeFileSync(path.join(dir, 'prefs.json'), '{ this is not json')
assert.deepStrictEqual(loadPrefs(dir), { enabled: null, railCollapsed: false })

// Kiểu sai từng field cũng phải chịu được.
fs.writeFileSync(path.join(dir, 'prefs.json'), JSON.stringify({ enabled: 'messenger', railCollapsed: 'true' }))
assert.deepStrictEqual(loadPrefs(dir), { enabled: null, railCollapsed: false })
fs.writeFileSync(path.join(dir, 'prefs.json'), JSON.stringify({ enabled: ['messenger', 7, null] }))
assert.deepStrictEqual(loadPrefs(dir), { enabled: ['messenger'], railCollapsed: false })

// Round trip.
savePrefs(dir, { enabled: ['messenger', 'zalo'], railCollapsed: true })
assert.deepStrictEqual(loadPrefs(dir), { enabled: ['messenger', 'zalo'], railCollapsed: true })

// Ghi xong không được để lại file tạm.
assert.deepStrictEqual(fs.readdirSync(dir), ['prefs.json'])

fs.rmSync(dir, { recursive: true, force: true })

console.log(`selftest OK (${SERVICES.length} services)`)
