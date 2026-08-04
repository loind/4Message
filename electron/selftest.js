// Check logic thuần, không cần GUI/mạng/login — build-electron.sh gọi làm cổng build.
// Chỉ giữ những case đã từng sai thật, không test getter.
const assert = require('assert')
const { isInternal, isSurface, resolveServices, unreadFromTitle, SERVICES } = require('./services')

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

assert.deepStrictEqual(resolveServices('threads,messenger').map(s => s.id), ['threads', 'messenger'])
assert.deepStrictEqual(resolveServices('nope').map(s => s.id), SERVICES.map(s => s.id))
assert.deepStrictEqual(resolveServices('threads,threads').map(s => s.id), ['threads'])

// Glyph rail nằm ở rail.html chứ không ở services.js, nên thêm service mà quên glyph là
// lỗi im lặng: tile hiện ra màu trơn không hình. Đây là cổng chặn.
const rail = require('fs').readFileSync(require('path').join(__dirname, 'rail.html'), 'utf8')
for (const s of SERVICES) {
  assert.ok(rail.includes(`${s.id}: '`), `thiếu glyph rail cho service: ${s.id}`)
}

console.log(`selftest OK (${SERVICES.length} services)`)
