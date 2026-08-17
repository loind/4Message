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
