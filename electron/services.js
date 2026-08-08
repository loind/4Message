// Nguồn duy nhất định nghĩa kênh: url, surface, hideRules.
//
// Trước đây đây là mirror tay của bản Swift; bản Swift đã xoá nên file này là bản chính.
//
// Bốn bẫy selector đã mắc ở bản Swift, đừng lặp:
//   1. `[role="navigation"]` trên facebook.com có 3 vùng, một trong đó là THREAD LIST.
//   2. `[role="navigation"]` trên instagram.com CHÍNH LÀ panel danh sách hội thoại.
//   3. `input[role="combobox"]` khớp cả ô "Search Messenger" của chính Messenger.
//   4. `[aria-label*="Facebook" i]` khớp cả một tin nhắn — nội dung tin nhắn cũng vào
//      aria-label. Luôn khớp CHÍNH XÁC.
// Chi tiết: docs/ui-discipline.md

'use strict'

/** @typedef {{host: string, pathPrefix?: string}} SurfaceRule */

const SERVICES = [
  {
    id: 'messenger',
    title: 'Messenger',
    url: 'https://www.facebook.com/messages/',
    tint: '#4a84ff',
    // pathPrefix gắn với HOST chứ không phải service: facebook.com chỉ có /messages là
    // chat, còn messenger.com và m.me thì cả domain đều là chat.
    surface: [
      { host: 'facebook.com', pathPrefix: '/messages' },
      { host: 'messenger.com' },
      { host: 'm.me' },
    ],
    // Badge phải đọc theo luật riêng của facebook.com — xem messengerUnread(). Cờ này gắn
    // với SURFACE, không với kênh: đổi url về messenger.com thì bỏ nó đi, title bên đó chỉ
    // đếm tin nhắn nên unreadFromTitle dùng thẳng được.
    unreadRule: 'facebook',
    hideRules: [
      ['tab bar', '[role="navigation"]:has(a[href^="/marketplace/"])'],
      ['search input', 'input[aria-label="Search Facebook"]'],
      // Ẩn <input> thôi chưa đủ: nút nhìn thấy được là <label> bọc ngoài.
      // BẮT BUỘC có `>` — thiếu thì :has() khớp mọi ancestor tới <body>, ẩn sạch trang.
      ['search button', '*:has(> input[aria-label="Search Facebook"])'],
      ['typeahead x', '[role="button"][aria-label="Exit typeahead"]'],
      ['facebook menu', '[role="button"][aria-label="Facebook menu"]'],
    ],
  },
  {
    id: 'instagram',
    title: 'Instagram',
    url: 'https://www.instagram.com/direct/inbox/',
    tint: '#e84190',
    surface: [{ host: 'instagram.com', pathPrefix: '/direct' }],
    // Rail trái nằm NGOÀI [role="navigation"] — nhắm theo href, độc lập ngôn ngữ và
    // tài khoản. Không ẩn link profile: path chứa username.
    hideRules: [
      ['home', 'a[href="/"]'],
      ['reels', 'a[href^="/reels/"]'],
      ['explore', 'a[href^="/explore/"]'],
    ],
  },
  {
    id: 'threads',
    title: 'Threads',
    // Mở feed. DM vẫn tới được bằng nav của Threads (/messages/, KHÔNG phải /direct/).
    url: 'https://www.threads.com/',
    tint: '#57575f',
    // Cả domain, KHÔNG chỉ /messages: xem feed thì bài viết/profile/search phải ở lại
    // trong app, giới hạn /messages làm mọi bài bật ra browser.
    surface: [
      { host: 'threads.com' },
      { host: 'threads.net' },
    ],
    // Cố tình rỗng — nav của Threads là đường duy nhất đi giữa feed và DM.
    hideRules: [],
  },
  {
    id: 'zalo',
    title: 'Zalo',
    // Đo được (probe 2026-08-04): chat.zalo.me redirect sang
    // id.zalo.me/account?continue=... khi chưa login, QR render bình thường, KHÔNG có màn
    // "trình duyệt không hỗ trợ" — UA của app đã bỏ token Electron nên trông như Chrome.
    url: 'https://chat.zalo.me/',
    tint: '#0068ff',
    // Cả hai host đều là surface: chat là nơi chat, id là màn login. Thiếu id.zalo.me thì
    // link trên trang login (đổi ngôn ngữ) bị đẩy ra browser giữa luồng đăng nhập.
    // KHÔNG mở cả zalo.me: profile/bài viết công khai nằm ở đó, giữ trong app là lặp lại
    // đúng cái bug link facebook.com từng gây ra.
    surface: [
      { host: 'chat.zalo.me' },
      { host: 'id.zalo.me' },
    ],
    // Zalo Web chỉ có chat, không có feed/marketplace để tách khỏi chrome.
    hideRules: [],
  },
]

/** Host được phép LOAD (hợp của mọi service + CDN + domain login). Rộng hơn `surface`. */
const INTERNAL_HOSTS = [
  'messenger.com', 'facebook.com', 'fbcdn.net', 'fb.com', 'm.me',
  'instagram.com', 'cdninstagram.com',
  'threads.com', 'threads.net',
  // Zalo: login đi chat.zalo.me → id.zalo.me. `zdn.vn`/`zadn.vn` là CDN (static, avatar,
  // captcha) — đo bằng probe, thiếu chúng thì captcha và avatar không load.
  'zalo.me', 'zdn.vn', 'zadn.vn',
]

function hostMatches (host, domain) {
  return host === domain || host.endsWith('.' + domain)
}

function isInternal (urlString) {
  try {
    const host = new URL(urlString).hostname.toLowerCase()
    return INTERNAL_HOSTS.some(d => hostMatches(host, d))
  } catch { return false }
}

/**
 * Link user CLICK có được giữ trong app không. Khác `isInternal` — cái đó chỉ trả lời
 * "host nào được phép load" và buộc phải rộng vì luồng login redirect qua nhiều domain.
 *
 * Dùng chung cho mọi service là sai: link facebook.com trong tin nhắn từng làm app rời
 * khỏi Messenger và không có đường về.
 */
function isSurface (urlString, service) {
  let host, path
  try {
    const u = new URL(urlString)
    host = u.hostname.toLowerCase()
    path = u.pathname
  } catch { return false }

  return service.surface.some(rule => {
    if (!hostMatches(host, rule.host)) return false
    if (!rule.pathPrefix) return true
    // Khớp chính xác prefix hoặc có `/` ngay sau — để `/messagesfake` không lọt.
    return path === rule.pathPrefix || path.startsWith(rule.pathPrefix + '/')
  })
}

/** `FBMESS_SERVICES=messenger,instagram`. Bỏ id lạ, loại trùng, giữ thứ tự user viết. */
function resolveServices (raw) {
  if (!raw || !raw.trim()) return SERVICES.slice()
  const seen = new Set()
  const picked = []
  for (const id of raw.split(',').map(s => s.trim().toLowerCase()).filter(Boolean)) {
    if (seen.has(id)) continue
    const s = SERVICES.find(x => x.id === id)
    if (!s) continue
    seen.add(id)
    picked.push(s)
  }
  return picked.length ? picked : SERVICES.slice()
}

/**
 * Số chưa đọc từ đầu document.title: `"(3) Chats · Messenger"` → `"3"`.
 *
 * Đúng cho messenger.com / instagram.com — nơi title chỉ đếm tin nhắn. KHÔNG đúng cho
 * facebook.com: xem messengerUnread().
 */
function unreadFromTitle (title) {
  if (!title || !title.startsWith('(')) return null
  const close = title.indexOf(')')
  if (close < 0) return null
  const inner = title.slice(1, close)
  if (!inner || !/^\d[\d+]*$/.test(inner)) return null
  return inner
}

/**
 * Số tin nhắn chưa đọc trên surface `facebook.com/messages`. Đo trên tài khoản thật
 * 2026-08-07, cả hai cái bẫy dưới đây đều bắt được trong log:
 *
 * 1. `(N)` trong title facebook.com là TỔNG badge toàn site — tin nhắn CỘNG thông báo. Một
 *    thông báo fanpage cũng đẩy title lên `(1)`, đúng lúc nút chuông mang text "Number of
 *    unread notifications". Nên phải trừ số của chuông ra, không thì badge app báo tin nhắn
 *    trong khi chỉ có ai đó comment.
 * 2. Facebook nhấp nháy title mỗi 2 giây sang `"Ai đó messaged you"` rồi quay lại. Dạng đó
 *    KHÔNG mang số; đọc thẳng thì badge chớp N→0→N→0 suốt thời gian còn tin chưa đọc. Nó
 *    nghĩa là "chưa biết" chứ không phải "đã đọc hết" — chỉ title nghỉ (`"Messenger |
 *    Facebook"`) mới là bằng chứng hết tin.
 *
 * `notifCount < 0` = không đọc được chuông → KHÔNG trừ. Badge cao hơn thực còn hơn nuốt mất
 * tin nhắn: báo tin là lý do app tồn tại.
 *
 * @param {string} title document.title hiện tại
 * @param {number} notifCount số trên chuông thông báo, `-1` nếu không đọc được
 * @param {string|null} prev giá trị badge đang giữ, dùng khi title không kết luận được
 */
function messengerUnread (title, notifCount, prev) {
  const total = unreadFromTitle(title)
  if (total === null) {
    // Chỉ dạng flash mới được giữ giá trị cũ. Mọi title khác (kể cả title nghỉ) là bằng
    // chứng đã đọc hết — nhận nhầm ở đây thì badge kẹt số cũ vĩnh viễn.
    return / messaged /i.test(title || '') ? (prev ?? null) : null
  }
  // `"9+"` không phải số đếm được, trừ đi cũng vô nghĩa — để nguyên.
  if (!/^\d+$/.test(total)) return total
  const n = parseInt(total, 10) - (notifCount > 0 ? notifCount : 0)
  return n > 0 ? String(n) : null
}

/**
 * Kênh nào đang bật. `universe` là danh sách khả dụng (từ FBMESS_SERVICES); prefs chỉ
 * bật/tắt TRONG đó.
 *
 * Không bao giờ trả rỗng: cửa sổ 0 kênh không có đường thoát bằng chuột, mà prefs.json là
 * file người dùng sửa được bằng tay nên phải chịu được nội dung rác.
 */
function resolveEnabled (universe, prefs) {
  const want = prefs && Array.isArray(prefs.enabled) ? prefs.enabled : null
  if (!want) return universe.slice()
  const set = new Set(want.filter(x => typeof x === 'string'))
  // Lọc theo `universe` nên thứ tự canonical và tính duy nhất đều có sẵn.
  const picked = universe.filter(s => set.has(s.id))
  return picked.length ? picked : universe.slice()
}

/** Rail chỉ có nghĩa khi có nhiều hơn một kênh để chọn. */
function railVisible (enabledCount, collapsed) {
  return enabledCount > 1 && !collapsed
}

module.exports = { SERVICES, INTERNAL_HOSTS, isInternal, isSurface, resolveServices, unreadFromTitle, messengerUnread, resolveEnabled, railVisible }
