// Mirror của Sources/Messenger/Services.swift. Giữ giống hệt để hai bản so sánh được và
// để bài học selector không phải học lại.
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
    // DM của Threads ở /messages/, KHÔNG phải /direct/ — suy diễn theo Instagram là sai.
    url: 'https://www.threads.com/messages/',
    tint: '#57575f',
    surface: [
      { host: 'threads.com', pathPrefix: '/messages' },
      { host: 'threads.net', pathPrefix: '/messages' },
    ],
    hideRules: [
      ['logo', 'a[href="/"]'],
      ['search', 'a[href="/search"]'],
      ['activity', 'a[href="/activity"]'],
      ['insights', 'a[href^="/insights/"]'],
      ['saved', 'a[href^="/saved/"]'],
    ],
  },
]

/** Host được phép LOAD (hợp của mọi service + CDN + domain login). Rộng hơn `surface`. */
const INTERNAL_HOSTS = [
  'messenger.com', 'facebook.com', 'fbcdn.net', 'fb.com', 'm.me',
  'instagram.com', 'cdninstagram.com',
  'threads.com', 'threads.net',
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

/** Số chưa đọc từ đầu document.title: `"(3) Chats · Messenger"` → `"3"`. */
function unreadFromTitle (title) {
  if (!title || !title.startsWith('(')) return null
  const close = title.indexOf(')')
  if (close < 0) return null
  const inner = title.slice(1, close)
  if (!inner || !/^\d[\d+]*$/.test(inner)) return null
  return inner
}

module.exports = { SERVICES, INTERNAL_HOSTS, isInternal, isSurface, resolveServices, unreadFromTitle }
