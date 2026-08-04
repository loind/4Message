// Check logic thuần, không cần GUI/mạng/login — build-electron.sh gọi làm cổng build.
// Chỉ giữ những case đã từng sai thật, không test getter.
const assert = require('assert')
const { isInternal, isSurface, resolveServices, unreadFromTitle, SERVICES } = require('./services')

const messenger = SERVICES.find(s => s.id === 'messenger')
const threads = SERVICES.find(s => s.id === 'threads')

// pathPrefix gắn với host: facebook.com chỉ /messages là chat, messenger.com cả domain.
assert.ok(isSurface('https://www.facebook.com/messages/t/123', messenger))
assert.ok(isSurface('https://www.messenger.com/t/123', messenger))
assert.ok(!isSurface('https://www.facebook.com/marketplace/', messenger))
// Lỗi từng mắc: link facebook.com trong tin nhắn chiếm cửa sổ, không có đường về.
assert.ok(!isSurface('https://www.facebook.com/some.page', messenger))
// Prefix phải khớp trọn segment, không thì /messagesfake lọt.
assert.ok(!isSurface('https://www.facebook.com/messagesfake', messenger))
// DM của Threads ở /messages/, KHÔNG phải /direct/.
assert.ok(isSurface('https://www.threads.com/messages/', threads))
assert.ok(!isSurface('https://www.threads.com/direct/', threads))

// isInternal rộng hơn isSurface — luồng login redirect qua nhiều domain của Meta.
assert.ok(isInternal('https://static.xx.fbcdn.net/x.js'))
assert.ok(!isInternal('https://example.com/'))
// Tránh bẫy endsWith: notfacebook.com KHÔNG phải facebook.com.
assert.ok(!isInternal('https://notfacebook.com/'))

assert.strictEqual(unreadFromTitle('(3) Chats · Messenger'), '3')
assert.strictEqual(unreadFromTitle('(9+) Instagram'), '9+')
assert.strictEqual(unreadFromTitle('Messenger'), null)
assert.strictEqual(unreadFromTitle('(hi) x'), null)

assert.deepStrictEqual(resolveServices('threads,messenger').map(s => s.id), ['threads', 'messenger'])
assert.deepStrictEqual(resolveServices('nope').map(s => s.id), SERVICES.map(s => s.id))
assert.deepStrictEqual(resolveServices('threads,threads').map(s => s.id), ['threads'])

console.log(`selftest OK (${SERVICES.length} services)`)
