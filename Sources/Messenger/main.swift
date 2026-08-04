import AppKit
import Carbon.HIToolbox
import UserNotifications
import WebKit

/// Mốc đo khởi động. Khai báo đầu tiên để chạy sớm nhất trong top-level code.
/// Không tính được phần dyld load trước `main` — phần đó đo từ shell (`startup.sh`).
let launchClock = Date()

/// Host được phép LOAD trong app (hợp của mọi service, cộng CDN và domain login).
/// Khác với `isSurface` — cái đó quyết định link user CLICK có ở lại trong app không.
let internalHosts = [
    "messenger.com", "facebook.com", "fbcdn.net", "fb.com", "m.me",
    "instagram.com", "cdninstagram.com",
    "threads.com", "threads.net",
    // Zalo: login đi chat.zalo.me → id.zalo.me. `zdn.vn`/`zadn.vn` là CDN (static, avatar,
    // captcha) — đo bằng probe, thiếu chúng thì captcha và avatar không load.
    "zalo.me", "zdn.vn", "zadn.vn",
]

/// Dùng surface Messenger trong facebook.com, không dùng messenger.com.
/// Lý do: Meta ship tính năng mới (Meta AI) vào facebook.com trước, messenger.com bị
/// bỏ lại — dấu hiệu Meta chỉ còn đầu tư một surface.
/// Đánh đổi: nặng hơn ~68 MB khi ẩn. Chi tiết: docs/decisions/2026-07-28-*.md
///
/// Đổi ngược không mất gì: hai origin cùng tồn tại trong data store, lịch sử E2EE của
/// messenger.com nằm nguyên. Chỉ cần `FBMESS_URL=https://www.messenger.com/`.
let defaultStartURL = URL(string: "https://www.facebook.com/messages/")!

/// URL khởi động, override bằng `FBMESS_URL` để thử surface khác không cần rebuild.
/// Chỉ nhận https và host trong `internalHosts` — env var không được trở thành đường
/// trỏ app tới site bất kỳ.
func resolveStartURL(_ raw: String?) -> URL {
    guard let raw, !raw.isEmpty,
          let url = URL(string: raw),
          url.scheme == "https",
          isInternal(url)
    else { return defaultStartURL }
    return url
}

let messengerURL = resolveStartURL(ProcessInfo.processInfo.environment["FBMESS_URL"])

/// Phần đuôi UA để WKWebView trông như Safari. Đọc version Safari thật của máy nếu
/// được, không thì fallback. WebKit build number `605.1.15` đã có trong UA mặc định.
let safariUserAgentSuffix: String = {
    let plist = "/Applications/Safari.app/Contents/Info.plist"
    if let info = NSDictionary(contentsOfFile: plist),
       let full = info["CFBundleShortVersionString"] as? String {
        // "26.5.2" → "26.5" (Safari chỉ để major.minor trong UA)
        let parts = full.split(separator: ".").prefix(2).joined(separator: ".")
        return "Version/\(parts) Safari/605.1.15"
    }
    return "Version/26.5 Safari/605.1.15"
}()

/// UA ghi đè hoàn toàn, để thử site mobile: `FBMESS_UA=mobile` hoặc một chuỗi UA đầy đủ.
///
/// `applicationNameForUserAgent` chỉ GHÉP vào UA mặc định (vẫn ghi "Macintosh"), nên
/// không tới được site mobile — Facebook sniff thấy desktop và redirect m→www.
/// Phải dùng `webView.customUserAgent`.
let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

func resolveCustomUserAgent(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return raw.lowercased() == "mobile" ? mobileUserAgent : raw
}

let customUA = resolveCustomUserAgent(ProcessInfo.processInfo.environment["FBMESS_UA"])

/// `FBMESS_CONTENT_MODE=mobile|desktop|recommended` — cơ chế "Request Mobile Website"
/// của Safari. Header WebKit annotate `API_AVAILABLE(ios(13.0))` nhưng Swift vẫn expose
/// trên macOS và compile được; compile được KHÔNG đảm bảo có tác dụng, phải đo.
func resolveContentMode(_ raw: String?) -> WKWebpagePreferences.ContentMode {
    switch (raw ?? "").lowercased() {
    case "mobile": return .mobile
    case "desktop": return .desktop
    default: return .recommended
    }
}

let contentMode = resolveContentMode(ProcessInfo.processInfo.environment["FBMESS_CONTENT_MODE"])

/// `FBMESS_WINDOW=420x760` — đổi kích thước cửa sổ để đo ảnh hưởng của viewport.
/// Layer backing store và vùng graphics tỉ lệ với diện tích cửa sổ, nên đây là phần
/// viewport thật sự chi phối; còn `WebKit Malloc` (~500 MB) thì theo lượng nội dung
/// đã load, không theo viewport.
func resolveWindowSize(_ raw: String?) -> NSSize {
    let fallback = NSSize(width: 1100, height: 760)
    guard let raw else { return fallback }
    let parts = raw.lowercased().split(separator: "x")
    guard parts.count == 2,
          let w = Double(parts[0]), let h = Double(parts[1]),
          w >= 320, h >= 320, w <= 8000, h <= 8000
    else { return fallback }
    return NSSize(width: w, height: h)
}

let windowSize = resolveWindowSize(ProcessInfo.processInfo.environment["FBMESS_WINDOW"])

// MARK: - Chế độ hiệu năng

/// Bốn biến thể để bench. Chọn bằng `FBMESS_MODE`, mặc định `baseline`.
///
/// `WKPreferences.inactiveSchedulingPolicy` chỉ có hiệu lực khi web view *detached
/// khỏi view hierarchy* (theo header WebKit). Nên mọi mode khác baseline đều tháo
/// webView ra khỏi window khi ẩn — không tháo thì set policy vô nghĩa.
enum Mode: String, CaseIterable {
    case baseline   // giữ foreground assertion, không detach — hành vi ban đầu
    case throttle   // detach khi ẩn + CPU-throttle, JS vẫn chạy
    case suspend    // detach khi ẩn + suspend hẳn JS/layout
    case block      // throttle + chặn telemetry và media

    static var current: Mode {
        Mode(rawValue: ProcessInfo.processInfo.environment["FBMESS_MODE"] ?? "") ?? .baseline
    }

    /// Giữ assertion chặn App Nap. Chỉ baseline làm — đây là thứ nghi ngăn WebKit prune.
    var holdsAwakeAssertion: Bool { self == .baseline }

    var detachesWhenHidden: Bool { self != .baseline }

    var schedulingPolicy: WKPreferences.InactiveSchedulingPolicy {
        switch self {
        case .baseline: return WKPreferences.InactiveSchedulingPolicy.none
        case .throttle, .block: return .throttle
        case .suspend: return .suspend
        }
    }

    var blocksTelemetryAndMedia: Bool { self == .block }
}

/// `FBMESS_DIAG=1` để bật probe chẩn đoán. Mặc định tắt cho khỏi ồn.
let diagnosticsEnabled = ProcessInfo.processInfo.environment["FBMESS_DIAG"] == "1"

/// Chỉ đếm element + tìm keyword trạng thái. Không đọc nội dung hội thoại.
let pageStateProbeJS = #"""
(() => {
  const t = document.body ? (document.body.innerText || '') : '';
  const has = (re) => re.test(t);
  return JSON.stringify({
    textLen: t.length,
    threadLinks: document.querySelectorAll('a[href*="/t/"]').length,
    rows: document.querySelectorAll('[role="row"]').length,
    gridRows: document.querySelectorAll('[role="grid"] [role="row"]').length,
    imgs: document.querySelectorAll('img').length,
    pin: has(/\bPIN\b/i),
    restore: has(/restore|khôi phục|khoi phuc/i),
    device: has(/\bdevice\b|thiết bị|thiet bi/i),
    // "trình duyệt" trần gây false positive với mọi thông báo cookie — phải đi kèm ngữ cảnh.
    unsupported: has(/unsupported browser|not supported|update your browser|cập nhật trình duyệt/i),
    e2ee: has(/end-to-end|end to end|mã hoá|ma hoa|encrypted/i),
    login: has(/log in|đăng nhập|dang nhap|password|mật khẩu/i),
    // Dấu vết Meta AI — dùng để so phân kỳ tính năng giữa messenger.com và facebook.com.
    metaAiText: has(/meta ai/i),
    // Chỉ khớp chuỗi "Meta AI" đầy đủ. `[aria-label*="AI" i]` khớp cả "Mail"/"Main"/
    // "Available" nên vô dụng — đã bỏ.
    metaAiNodes: document.querySelectorAll('[aria-label*="Meta AI" i], a[href*="meta.ai"]').length,
  });
})();
"""#

/// Soi chrome của Facebook để chọn selector ẩn. Chỉ quét thanh trên cùng (top < 60px) và
/// các vùng landmark — KHÔNG chạm `[role="grid"]` / `[role="navigation"][aria-label*="hread"]`
/// (chỗ chứa tên liên hệ).
let navProbeJS = #"""
(() => {
  const clip = (s) => (s || '').trim().slice(0, 30);
  const box = (el) => {
    const r = el.getBoundingClientRect();
    return `${Math.round(r.width)}x${Math.round(r.height)}@${Math.round(r.left)},${Math.round(r.top)}`;
  };
  const path = (el) => {
    try { return new URL(el.href, location.origin).pathname.slice(0, 26) } catch { return '' }
  };
  const isPrivate = (el) => el.closest('[role="grid"], [role="main"]');

  // Mọi control tương tác nằm trong dải 60px trên cùng.
  const topBar = [...document.querySelectorAll(
      'a[href], [role="button"], [role="link"], [role="search"], input, [role="combobox"]')]
    .filter(el => !isPrivate(el))
    .filter(el => { const r = el.getBoundingClientRect(); return r.top < 60 && r.width > 0 && r.height > 0 })
    .slice(0, 24)
    .map(el => ({
      tag: el.tagName.toLowerCase(),
      role: el.getAttribute('role') || '',
      label: clip(el.getAttribute('aria-label')),
      ph: clip(el.getAttribute('placeholder')),
      path: path(el),
      rect: box(el),
    }));

  const regions = (sel) => [...document.querySelectorAll(sel)].map((n, i) => ({
    i, label: clip(n.getAttribute('aria-label')), rect: box(n),
  }));

  // Toàn trang, không giới hạn thanh trên: để phát hiện va chạm với ô search riêng
  // của Messenger trước khi dùng selector cấu trúc.
  const all = (sel) => [...document.querySelectorAll(sel)].map(el => ({
    tag: el.tagName.toLowerCase(),
    label: clip(el.getAttribute('aria-label')) || clip(el.getAttribute('placeholder')),
    rect: box(el),
  }));

  // Chuỗi ancestor của ô search Facebook đã ẩn — để tìm wrapper còn hiện (nút tròn).
  const chain = (() => {
    let el = document.querySelector('input[aria-label="Search Facebook"]');
    const out = [];
    for (let i = 0; el && i < 7; i++, el = el.parentElement) {
      const cs = getComputedStyle(el);
      out.push({
        lvl: i,
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') || '',
        label: clip(el.getAttribute('aria-label')),
        rect: box(el),
        display: cs.display,
        bg: cs.backgroundColor,
        radius: cs.borderRadius,
      });
    }
    return out;
  })();

  // Mọi control ở góc trên-trái (x<420, y<220) — vùng chứa nút tròn trong ảnh.
  const corner = [...document.querySelectorAll('[role="button"], [role="link"], a[href], svg, i')]
    .filter(el => !isPrivate(el))
    .filter(el => {
      const r = el.getBoundingClientRect();
      return r.top < 220 && r.left < 420 && r.width >= 16 && r.height >= 16;
    })
    .slice(0, 20)
    .map(el => ({
      tag: el.tagName.toLowerCase(),
      role: el.getAttribute('role') || '',
      label: clip(el.getAttribute('aria-label')),
      rect: box(el),
    }));

  return JSON.stringify({
    searchAncestors: chain,
    corner,
    searchLabelled: all('[aria-label*="earch" i]'),
  });
})();
"""#

/// Probe cấu trúc TỔNG QUÁT, không giả định layout.
///
/// `navProbeJS` được viết cho Facebook: chỉ quét dải `top < 60px` và landmark
/// `[role="banner"]`/`[role="navigation"]`. Instagram dùng sidebar DỌC nên probe đó trả
/// về rỗng hoàn toàn. Probe này liệt kê link theo `href` ở mọi vị trí — href là tín hiệu
/// độc lập ngôn ngữ, đúng thứ cần để viết selector bền.
///
/// Không đọc nội dung hội thoại: bỏ qua mọi thứ trong `[role="grid"]`, và chỉ lấy
/// pathname + aria-label của phần tử điều hướng.
let layoutProbeJS = #"""
(() => {
  const clip = (s) => (s || '').trim().slice(0, 26);
  const box = (el) => {
    const r = el.getBoundingClientRect();
    return `${Math.round(r.width)}x${Math.round(r.height)}@${Math.round(r.left)},${Math.round(r.top)}`;
  };
  const vis = (el) => { const r = el.getBoundingClientRect(); return r.width > 8 && r.height > 8 };

  // Link điều hướng: nav rail của Instagram/Threads là các <a href>.
  const links = [...document.querySelectorAll('a[href]')]
    .filter(el => !el.closest('[role="grid"]') && vis(el))
    .map(el => {
      let path = '';
      try { path = new URL(el.href, location.origin).pathname } catch {}
      return { path: path.slice(0, 24), label: clip(el.getAttribute('aria-label')), rect: box(el) };
    })
    // Bỏ link trùng path để danh sách đọc được.
    .filter((e, i, a) => a.findIndex(x => x.path === e.path) === i)
    .slice(0, 26);

  // Có những role nào, mỗi role bao nhiêu phần tử — để biết landmark nào dùng được.
  const roles = {};
  document.querySelectorAll('[role]').forEach(el => {
    const r = el.getAttribute('role');
    if (!vis(el)) return;
    roles[r] = (roles[r] || 0) + 1;
  });

  // Nút không phải link (icon-only) ngoài vùng hội thoại.
  const buttons = [...document.querySelectorAll('[role="button"], button')]
    .filter(el => !el.closest('[role="grid"], [role="main"]') && vis(el))
    .map(el => ({ label: clip(el.getAttribute('aria-label')), rect: box(el) }))
    .filter(e => e.label)
    .slice(0, 18);

  // Con trực tiếp của vùng navigation — để biết rail gồm những gì (nhiều item là
  // [role="button"] không có aria-label nên không nhận diện được qua label).
  const navKids = [...document.querySelectorAll('[role="navigation"] a, [role="navigation"] [role="button"], [role="navigation"] svg')]
    .filter(vis).slice(0, 20)
    .map(el => {
      let path = '';
      try { if (el.href) path = new URL(el.href, location.origin).pathname } catch {}
      return { tag: el.tagName.toLowerCase(), role: el.getAttribute('role') || '',
               path: path.slice(0, 22), label: clip(el.getAttribute('aria-label')), rect: box(el) };
    });

  // Mọi button có label, KHÔNG loại trừ [role="main"] — Threads không có landmark main.
  const allButtons = [...document.querySelectorAll('[role="button"], button')]
    .filter(el => !el.closest('[role="grid"]') && vis(el))
    .map(el => ({ label: clip(el.getAttribute('aria-label')), rect: box(el) }))
    .filter(e => e.label).slice(0, 20);

  return JSON.stringify({ links, roles, buttons, navKids, allButtons });
})();
"""#

/// Bench: tự ẩn cửa sổ sau N giây để đo trạng thái hidden mà không cần thao tác tay.
let benchHideAfter = TimeInterval(ProcessInfo.processInfo.environment["FBMESS_BENCH_HIDE_AFTER"] ?? "") ?? 0

/// Chặn endpoint telemetry của Facebook + toàn bộ resource loại `media`.
/// Không chặn `image` vì sẽ phá UX chat.
let blockRulesJSON = #"""
[
  {"trigger":{"url-filter":"facebook\\.com/ajax/bz"},"action":{"type":"block"}},
  {"trigger":{"url-filter":"facebook\\.com/ajax/bnzai"},"action":{"type":"block"}},
  {"trigger":{"url-filter":"/common/scribe_endpoint\\.php"},"action":{"type":"block"}},
  {"trigger":{"url-filter":"/ajax/log_error"},"action":{"type":"block"}},
  {"trigger":{"url-filter":".*","resource-type":["media"]},"action":{"type":"block"}}
]
"""#

/// Ghi thẳng stderr — `NSLog` không đến được unified log khi process chạy như
/// child của shell, nên bench không đọc được.
func benchLog(_ message: String) {
    FileHandle.standardError.write(Data("[fbmess] \(message)\n".utf8))
}

// MARK: - Thông tin bản build

/// Gộp thành một khối text để dán khi báo lỗi.
///
/// Lý do tồn tại: đã xảy ra chuyện một máy chạy bản cũ thiếu fix mà không ai biết,
/// và không có cách nào kiểm tra ngoài đoán. Commit là thứ định danh duy nhất đáng tin.
func versionSummary(version: String, build: String, commit: String, dirty: Bool,
                    buildDate: String, surface: String, mode: String) -> String {
    let commitText = dirty ? "\(commit) (DIRTY — build từ working tree chưa commit)" : commit
    return """
    FB Mess \(version) (build \(build))
    commit   \(commitText)
    built    \(buildDate)
    surface  \(surface)
    mode     \(mode)
    macOS    \(ProcessInfo.processInfo.operatingSystemVersionString)
    """
}

/// Đọc từ Info.plist — build.sh nhúng vào lúc đóng bundle. Chạy qua `swift run` thì
/// không có bundle nên trả "unknown", không crash.
func currentVersionSummary() -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    let s = { (key: String) in info[key] as? String ?? "unknown" }
    return versionSummary(
        version: s("CFBundleShortVersionString"),
        build: s("CFBundleVersion"),
        commit: s("FBMessGitCommit"),
        dirty: (info["FBMessGitDirty"] as? Bool) ?? false,
        buildDate: s("FBMessBuildDate"),
        surface: messengerURL.absoluteString,
        mode: Mode.current.rawValue
            + " services=" + resolveServices(info["__unused"] as? String
                ?? ProcessInfo.processInfo.environment["FBMESS_SERVICES"]).map(\.id).joined(separator: "+")
            + " topology=" + Topology.resolve(ProcessInfo.processInfo.environment["FBMESS_TOPOLOGY"]).rawValue
    )
}

// MARK: - Logic thuần (được cover bởi `--selftest`)

/// Messenger đặt số tin chưa đọc ở đầu `document.title`: `"(3) Chats · Messenger"`.
/// Dùng title thay vì parse DOM vì DOM class của Messenger bị obfuscate và đổi liên tục.
func unreadBadge(from title: String?) -> String? {
    guard let title, title.hasPrefix("("),
          let close = title.firstIndex(of: ")")
    else { return nil }

    let inner = String(title[title.index(after: title.startIndex)..<close])
    guard let first = inner.first, first.isNumber,
          inner.allSatisfy({ $0.isNumber || $0 == "+" })
    else { return nil }

    return inner
}

func isInternal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return internalHosts.contains { host == $0 || host.hasSuffix("." + $0) }
}

// `isSurface(_:of:)` nằm ở Services.swift — nó cần biết service nào nên không thể là
// hàm global không tham số như bản `isMessengerSurface` cũ.

/// Dùng `fatalError` chứ KHÔNG dùng `precondition`/`assert`: `-Ounchecked` xoá cả hai,
/// khiến selftest luôn "pass" dù logic sai. `fatalError` sống sót mọi mức tối ưu.
func check(_ condition: Bool, _ what: String, line: UInt = #line) {
    if !condition { fatalError("selftest FAILED (dòng \(line)): \(what)") }
}

func runSelftest() {
    check(unreadBadge(from: nil) == nil, "title nil")
    check(unreadBadge(from: "Messenger") == nil, "không có số")
    check(unreadBadge(from: "Chats · Messenger") == nil, "không có ngoặc")
    check(unreadBadge(from: "(3) Messenger") == "3", "1 chữ số")
    check(unreadBadge(from: "(12) Chats · Messenger") == "12", "2 chữ số")
    check(unreadBadge(from: "(9+) Chats · Messenger") == "9+", "dạng 9+")
    check(unreadBadge(from: "(abc) Messenger") == nil, "ngoặc chứa chữ")
    check(unreadBadge(from: "()") == nil, "ngoặc rỗng")

    check(isInternal(URL(string: "https://www.messenger.com/t/123")!), "messenger.com")
    check(isInternal(URL(string: "https://facebook.com/login")!), "facebook.com")
    check(isInternal(URL(string: "https://scontent.fbcdn.net/x.jpg")!), "subdomain fbcdn")
    check(!isInternal(URL(string: "https://evil-messenger.com/")!), "chặn suffix giả mạo")
    check(!isInternal(URL(string: "https://youtube.com/watch")!), "host ngoài")
    check(!isInternal(URL(string: "mailto:a@b.c")!), "scheme không có host")

    // Link click: chỉ surface Messenger được ở lại trong app.
    let msg = knownServices[0], ig = knownServices[1], th = knownServices[2], za = knownServices[3]
    check(isSurface(URL(string: "https://www.facebook.com/messages/")!, of: msg), "fb /messages/")
    check(isSurface(URL(string: "https://www.facebook.com/messages")!, of: msg), "fb /messages")
    check(isSurface(URL(string: "https://www.facebook.com/messages/e2ee/t/1")!, of: msg), "fb thread")
    check(isSurface(URL(string: "https://www.messenger.com/t/1")!, of: msg), "messenger.com")
    check(isSurface(URL(string: "https://m.me/abc")!, of: msg), "m.me")
    // Bug đã gây kẹt cửa sổ: link content facebook.com phải ra browser.
    check(!isSurface(URL(string: "https://www.facebook.com/facebook")!, of: msg), "fb page → browser")
    check(!isSurface(URL(string: "https://www.facebook.com/reel/1")!, of: msg), "fb reel → browser")
    check(!isSurface(URL(string: "https://www.facebook.com/messagesfake")!, of: msg), "prefix giả không lọt")
    check(!isSurface(URL(string: "https://evil-facebook.com/messages/")!, of: msg), "host giả mạo")
    check(!isSurface(URL(string: "https://youtube.com/watch")!, of: msg), "host ngoài")

    // Service không được nhận surface của service khác — nếu không, link Instagram
    // sẽ mở trong cửa sổ Messenger.
    check(isSurface(URL(string: "https://www.instagram.com/direct/inbox/")!, of: ig), "ig /direct")
    check(!isSurface(URL(string: "https://www.instagram.com/explore/")!, of: ig), "ig explore → browser")
    check(!isSurface(URL(string: "https://www.instagram.com/direct/")!, of: msg), "ig không thuộc messenger")
    check(!isSurface(URL(string: "https://www.facebook.com/messages/")!, of: ig), "fb không thuộc instagram")
    // Threads là kênh feed + DM: cả domain ở lại trong app. DM ở /messages/ (KHÔNG phải
    // /direct/ — suy diễn theo Instagram là sai).
    check(th.url.path == "/", "threads mở feed, không mở thẳng hộp thư")
    check(isSurface(URL(string: "https://www.threads.com/")!, of: th), "threads feed")
    check(isSurface(URL(string: "https://www.threads.com/messages/")!, of: th), "threads /messages/")
    check(isSurface(URL(string: "https://www.threads.net/messages/x")!, of: th), "threads.net cũng nhận")
    // Ba case dưới trước đây bị đẩy ra browser — xem feed thì phải ở lại trong app.
    check(isSurface(URL(string: "https://www.threads.com/@x")!, of: th), "profile threads ở lại app")
    check(isSurface(URL(string: "https://www.threads.com/@x/post/1")!, of: th), "bài viết ở lại app")
    check(isSurface(URL(string: "https://www.threads.com/search")!, of: th), "search threads ở lại app")
    check(!isSurface(URL(string: "https://evil-threads.com/")!, of: th), "host giả mạo threads")
    check(th.hideRules.isEmpty, "threads không ẩn nav — đó là đường về feed")
    // Zalo: service đầu tiên ngoài Meta. Login đi qua id.zalo.me nên host đó phải là
    // surface, còn zalo.me (profile, bài viết công khai) thì không.
    check(isSurface(URL(string: "https://chat.zalo.me/")!, of: za), "zalo chat")
    check(isSurface(URL(string: "https://id.zalo.me/account?continue=x")!, of: za), "zalo login")
    check(!isSurface(URL(string: "https://zalo.me/abc")!, of: za), "profile zalo → browser")
    check(!isSurface(URL(string: "https://chat.zalo.me.evil.com/")!, of: za), "host giả mạo zalo")
    check(!isSurface(URL(string: "https://chat.zalo.me/")!, of: msg), "zalo không thuộc messenger")
    check(isInternal(URL(string: "https://stc-chat.zdn.vn/x.js")!), "CDN zdn.vn load được")
    check(isInternal(URL(string: "https://s120-ava-talk.zadn.vn/a.jpg")!), "CDN zadn.vn load được")
    check(!isInternal(URL(string: "https://notzalo.me/")!), "notzalo.me không phải zalo.me")
    check(resolveServices("zalo").map(\.id) == ["zalo"], "zalo là service hợp lệ")
    check(!isSurface(URL(string: "https://www.threads.com/@x")!, of: ig), "threads không thuộc instagram")
    check(knownServices.allSatisfy { !$0.symbol.isEmpty }, "mọi service phải có SF Symbol")

    check(resolveServices(nil).map(\.id) == ["messenger"], "không set → chỉ messenger")
    check(resolveServices("").map(\.id) == ["messenger"], "rỗng → chỉ messenger")
    check(resolveServices("instagram,messenger").map(\.id) == ["instagram", "messenger"], "giữ thứ tự user")
    check(resolveServices("messenger,messenger").map(\.id) == ["messenger"], "loại trùng")
    check(resolveServices("nonsense").map(\.id) == ["messenger"], "id lạ → fallback")
    check(resolveServices("nonsense,instagram").map(\.id) == ["instagram"], "bỏ id lạ, giữ id đúng")
    // Threads không có hideRules (là feed, không có chat để tách) → chỉ kiểm tra rule
    // nào tồn tại thì phải hợp lệ, và id không trùng.
    check(knownServices.allSatisfy { $0.hideRules.allSatisfy { !$0.selector.isEmpty && !$0.name.isEmpty } },
          "mọi hide rule phải có name và selector")
    check(Set(knownServices.map(\.id)).count == knownServices.count, "id service không trùng")
    check(resolveServices("threads").map(\.id) == ["threads"], "threads là service hợp lệ")
    check(!makeHideChromeJS(serviceId: "x", rules: [HideRule("a", #"a[href="/"]"#)]).isEmpty, "sinh được JS")
    check(Topology.resolve(nil) == .tabs, "topology default tabs")
    check(Topology.resolve("windows") == .windows, "topology windows")
    check(Topology.resolve("rác") == .tabs, "topology rác → tabs")

    check(jsString("a\"b") == "\"a\\\"b\"", "escape JS string")

    check(resolveContentMode(nil) == .recommended, "không set → recommended")
    check(resolveContentMode("mobile") == .mobile, "mobile")
    check(resolveContentMode("desktop") == .desktop, "desktop")
    check(resolveContentMode("rác") == .recommended, "giá trị lạ → recommended")

    check(resolveWindowSize(nil) == NSSize(width: 1100, height: 760), "không set → mặc định")
    check(resolveWindowSize("420x760") == NSSize(width: 420, height: 760), "parse WxH")
    check(resolveWindowSize("420X760") == NSSize(width: 420, height: 760), "X hoa cũng được")
    check(resolveWindowSize("rác") == NSSize(width: 1100, height: 760), "chuỗi rác → mặc định")
    check(resolveWindowSize("10x10") == NSSize(width: 1100, height: 760), "quá nhỏ → mặc định")
    check(resolveWindowSize("99999x99999") == NSSize(width: 1100, height: 760), "quá lớn → mặc định")

    check(resolveCustomUserAgent(nil) == nil, "không set UA → dùng UA mặc định")
    check(resolveCustomUserAgent("") == nil, "UA rỗng → mặc định")
    check(resolveCustomUserAgent("mobile") == mobileUserAgent, "preset mobile")
    check(resolveCustomUserAgent("MOBILE") == mobileUserAgent, "preset không phân biệt hoa thường")
    check(resolveCustomUserAgent("Custom/1.0") == "Custom/1.0", "UA tuỳ ý giữ nguyên")
    check(mobileUserAgent.contains("iPhone"), "UA mobile phải nói iPhone")

    check(resolveStartURL(nil) == defaultStartURL, "không có env → default")
    check(resolveStartURL("") == defaultStartURL, "env rỗng → default")
    // Phải khác defaultStartURL, không thì test pass ngay cả khi hàm luôn trả default.
    check(resolveStartURL("https://www.messenger.com/").absoluteString
          == "https://www.messenger.com/", "override hợp lệ được tôn trọng")
    check(resolveStartURL("https://www.messenger.com/") != defaultStartURL,
          "override khác default (chống test tautology)")
    check(resolveStartURL("http://www.facebook.com/messages/") == defaultStartURL, "chặn http")
    check(resolveStartURL("https://evil.com/") == defaultStartURL, "chặn host ngoài")
    check(resolveStartURL("rác") == defaultStartURL, "chặn chuỗi rác")

    // Mode parsing + bảo đảm chỉ baseline giữ assertion / không detach.
    check(Mode(rawValue: "throttle") == .throttle, "parse mode hợp lệ")
    check(Mode(rawValue: "nonsense") == nil, "parse mode rác")
    check(Mode.allCases.filter(\.holdsAwakeAssertion) == [.baseline], "chỉ baseline giữ assertion")
    check(Mode.allCases.filter { !$0.detachesWhenHidden } == [.baseline], "chỉ baseline không detach")

    // Cảnh báo dirty phải xuất hiện, nếu không bản build không tái tạo được mà không ai biết.
    let clean = versionSummary(version: "0.1.0", build: "7", commit: "abc1234", dirty: false,
                              buildDate: "2026-07-28T09:00:00Z", surface: "https://x/", mode: "baseline")
    check(clean.contains("FB Mess 0.1.0 (build 7)"), "dòng đầu có version + build")
    check(clean.contains("commit   abc1234"), "có commit")
    check(!clean.lowercased().contains("dirty"), "clean thì không báo dirty")

    let dirty = versionSummary(version: "0.1.0", build: "7", commit: "abc1234", dirty: true,
                               buildDate: "2026-07-28T09:00:00Z", surface: "https://x/", mode: "baseline")
    check(dirty.contains("DIRTY"), "dirty thì phải báo DIRTY")

    // Rule list phải là JSON hợp lệ — sai cú pháp thì WebKit chỉ fail lúc runtime.
    check((try? JSONSerialization.jsonObject(with: Data(blockRulesJSON.utf8))) != nil,
          "blockRulesJSON là JSON hợp lệ")

    print("selftest OK")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
                         UNUserNotificationCenterDelegate {

    private let mode = Mode.current
    private let services = resolveServices(ProcessInfo.processInfo.environment["FBMESS_SERVICES"])
    private let topology = Topology.resolve(ProcessInfo.processInfo.environment["FBMESS_TOPOLOGY"])

    /// Một service = một webview = một WebContent process (origin khác nhau).
    private final class Runtime {
        let service: Service
        let webView: WKWebView
        var window: NSWindow?               // chỉ dùng ở topology .windows
        var titleObserver: NSKeyValueObservation?
        init(service: Service, webView: WKWebView) { self.service = service; self.webView = webView }
    }
    private var runtimes: [Runtime] = []
    private var activeIndex = 0

    private var window: NSWindow!
    /// Trỏ tới webview của service đang active. Giữ tên cũ để phần lớn code delegate
    /// không phải đổi khi lên multi-service.
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var serviceMenu: NSMenu?
    /// Rail chọn kênh trong cửa sổ (chỉ ở topology .tabs, khi có >1 service).
    private var webHost: NSView?
    private var railButtons: [NSButton] = []
    private var railBadges: [NSTextField] = []
    private var railView: NSView?
    private var railWidthConstraint: NSLayoutConstraint?
    private var railMenuItem: NSMenuItem?

    /// Nhớ trạng thái thu gọn qua lần chạy sau — thu gọn rồi mà mở lại app lại bung ra
    /// thì tính năng vô nghĩa.
    private static let railCollapsedKey = "railCollapsed"
    private var railCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.railCollapsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.railCollapsedKey) }
    }
    private var hotkey: Hotkey?
    private var activity: NSObjectProtocol?
    private var retryDelay: TimeInterval = 2

    /// Chỗ giữ contentView khi webView bị tháo ra (contentView không được nil).
    private lazy var placeholder = NSView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log ngay đầu tiên: đọc log mà không biết bản nào sinh ra nó thì vô dụng.
        for line in currentVersionSummary().split(separator: "\n") { benchLog(String(line)) }

        benchLog("mode=\(mode.rawValue) policy=\(mode.schedulingPolicy.rawValue) "
                 + "detach=\(mode.detachesWhenHidden) assertion=\(mode.holdsAwakeAssertion) "
                 + "block=\(mode.blocksTelemetryAndMedia) hideAfter=\(benchHideAfter)")

        buildMenu()
        buildUI()
        buildStatusItem()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        // ⌘⇧M toggle show/hide.
        hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_M),
                        modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.toggle()
        }

        if mode.holdsAwakeAssertion {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Messenger realtime connection"
            )
        }

        loadAllServices()

        benchLog(String(format: "ready main_ms=%.1f epoch=%.3f",
                        Date().timeIntervalSince(launchClock) * 1000,
                        Date().timeIntervalSince1970))

        if benchHideAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + benchHideAfter) { [weak self] in
                benchLog("bench: auto-hide")
                self?.hide()
            }
        }
    }

    // MARK: Setup

    private var activeService: Service { runtimes[activeIndex].service }

    private func service(for wv: WKWebView) -> Service {
        runtimes.first { $0.webView === wv }?.service ?? services[0]
    }

    private func buildUI() {
        runtimes = services.map { Runtime(service: $0, webView: makeWebView(for: $0)) }

        for rt in runtimes {
            rt.titleObserver = rt.webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                self?.applyTitle(wv.title, from: wv)
            }
        }

        switch topology {
        case .tabs:
            // 1 cửa sổ, webview không active thì DETACH — điều kiện để
            // inactiveSchedulingPolicy có hiệu lực.
            window = makeWindow(title: runtimes[0].service.title, autosave: "MessengerMain")
            if runtimes.count > 1 {
                window.contentView = buildRailContainer()
                attachWebView(runtimes[0].webView)
            } else {
                // 1 service thì không dựng rail — chiếm chỗ mà không chọn được gì.
                window.contentView = runtimes[0].webView
            }
            window.makeKeyAndOrderFront(nil)
        case .windows:
            // Mỗi service 1 cửa sổ. Cửa sổ bị che hoàn toàn thì macOS báo occluded và
            // WebKit cũng dừng render — nên topology này chỉ khác .tabs khi các cửa sổ
            // cùng nhìn thấy được.
            for (i, rt) in runtimes.enumerated() {
                let w = makeWindow(title: rt.service.title, autosave: "Window-\(rt.service.id)")
                w.contentView = rt.webView
                rt.window = w
                if i == 0 { window = w }
                w.makeKeyAndOrderFront(nil)
            }
        }

        webView = runtimes[0].webView
        activeIndex = 0
    }

    /// Rail dọc bên trái + vùng chứa webview.
    ///
    /// Dựng qua `Rail.make` — cùng hàm mà `tools/preview-rail.swift` dùng. Trước đây app
    /// và preview có code riêng, nên preview không thể phát hiện lỗi layout của app.
    private func buildRailContainer() -> NSView {
        let container = NSView()
        let host = NSView()
        webHost = host

        let build = Rail.make(services: services, target: self, action: #selector(railClicked(_:)))
        railButtons = build.buttons
        railBadges = build.badges
        let rail = build.view
        railView = rail

        for v in [rail, host] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        let railWidth = rail.widthAnchor.constraint(equalToConstant: Rail.width)
        railWidthConstraint = railWidth

        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rail.topAnchor.constraint(equalTo: container.topAnchor),
            railWidth,
            host.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        applyRailCollapsed(animated: false)
        return container
    }

    @objc private func railClicked(_ sender: NSButton) { select(index: sender.tag) }

    @objc private func toggleRail() {
        railCollapsed.toggle()
        applyRailCollapsed(animated: true)
    }

    private func applyRailCollapsed(animated: Bool) {
        let collapsed = railCollapsed
        railWidthConstraint?.constant = collapsed ? 0 : Rail.width
        railView?.isHidden = collapsed
        railMenuItem?.title = collapsed ? "Hiện cột kênh" : "Ẩn cột kênh"

        guard animated else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }
        benchLog("rail \(collapsed ? "thu gọn" : "bung")")
    }

    /// Gắn webview vào vùng chứa. Tháo cái cũ ra trước — đó cũng chính là "detach khỏi
    /// view hierarchy" mà inactiveSchedulingPolicy cần.
    private func attachWebView(_ wv: WKWebView) {
        guard let host = webHost else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        wv.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            wv.topAnchor.constraint(equalTo: host.topAnchor),
            wv.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    /// Xem trước thiết kế mà không cần chạy app: `./preview-rail.sh out.png`
    /// (render cả light và dark, dùng đúng `Rail.make`/`Rail.style` này).
    private func refreshRail() {
        guard !railButtons.isEmpty else { return }
        Rail.style(RailBuild(view: railView ?? NSView(), buttons: railButtons, badges: railBadges),
                   services: services, activeIndex: activeIndex)
    }

    private func makeWindow(title: String, autosave: String) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = title
        w.minSize = NSSize(width: 420, height: 400)
        w.delegate = self
        w.setFrameAutosaveName(autosave)
        if !w.setFrameUsingName(autosave) { w.center() }
        return w
    }

    private func makeWebView(for service: Service) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent → login sống qua restart

        // UA mặc định của WKWebView thiếu token `Version/... Safari/...`:
        //   Mozilla/5.0 (Macintosh; ...) AppleWebKit/605.1.15 (KHTML, like Gecko)
        // Facebook sniff UA, thiếu token này dễ bị serve bundle client hạn chế.
        // `applicationNameForUserAgent` được WebKit ghép vào cuối UA mặc định →
        // ra đúng format Safari. Bump khi Safari lên version mới.
        config.applicationNameForUserAgent = safariUserAgentSuffix
        config.preferences.inactiveSchedulingPolicy = mode.schedulingPolicy
        config.defaultWebpagePreferences.preferredContentMode = contentMode
        config.userContentController.add(self, name: "mbr")
        config.userContentController.addUserScript(
            WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // Rule ẩn chrome riêng từng service (Service.hideRules).
        if !service.hideRules.isEmpty,
           ProcessInfo.processInfo.environment["FBMESS_KEEP_FB_CHROME"] != "1" {
            config.userContentController.addUserScript(
                WKUserScript(source: makeHideChromeJS(serviceId: service.id, rules: service.hideRules),
                             injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        // Bật lại: nếu có navigation nào lọt qua luật link thì user vẫn thoát được,
        // không bị kẹt trên trang lạ.
        wv.allowsBackForwardNavigationGestures = true
        if let customUA { wv.customUserAgent = customUA }
        return wv
    }

    private func loadAllServices() {
        guard mode.blocksTelemetryAndMedia else {
            for rt in runtimes { rt.webView.load(URLRequest(url: rt.service.url)) }
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "fbmess-block",
            encodedContentRuleList: blockRulesJSON
        ) { [weak self] list, error in
            guard let self else { return }
            for rt in self.runtimes {
                if let list { rt.webView.configuration.userContentController.add(list) }
                rt.webView.load(URLRequest(url: rt.service.url))
            }
            benchLog(list != nil ? "content rule list đã áp dụng"
                                 : "content rule compile FAILED: \(String(describing: error))")
        }
    }

    /// Đổi service đang xem. Ở `.tabs` thì detach webview cũ khỏi view hierarchy —
    /// đó là điều kiện để `inactiveSchedulingPolicy` có tác dụng.
    @objc private func switchService(_ sender: NSMenuItem) {
        select(index: sender.tag)
    }

    private func select(index: Int) {
        guard index >= 0, index < runtimes.count else { return }
        activeIndex = index
        let rt = runtimes[index]
        webView = rt.webView

        switch topology {
        case .tabs:
            if webHost != nil { attachWebView(rt.webView) } else { window.contentView = rt.webView }
            window.title = rt.webView.title ?? rt.service.title
            window.makeKeyAndOrderFront(nil)
        case .windows:
            rt.window?.makeKeyAndOrderFront(nil)
        }
        refreshServiceMenu()
        refreshRail()
        NSApp.activate(ignoringOtherApps: true)
        benchLog("switch → \(rt.service.id)")
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "message.fill",
                                          accessibilityDescription: "Messenger")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
    }

    /// `document.title` của Messenger là nguồn duy nhất cho cả 3 chỗ: tiêu đề cửa sổ,
    /// badge dock, và số bên cạnh icon menu bar.
    private func applyTitle(_ title: String?, from source: WKWebView) {
        // Ở .windows mỗi service có cửa sổ riêng → đặt title cho đúng cửa sổ đó,
        // kể cả khi nó không phải service đang active.
        if let rt = runtimes.first(where: { $0.webView === source }),
           let own = rt.window, let title, !title.isEmpty {
            own.title = title
        }
        // Số chưa đọc của TỪNG service lên rail — đây là lý do chính để có rail:
        // thấy service khác có tin mới mà không phải bấm qua.
        if let i = runtimes.firstIndex(where: { $0.webView === source }), i < railBadges.count {
            let unread = unreadBadge(from: title)
            railBadges[i].stringValue = unread ?? ""
            railBadges[i].isHidden = unread == nil
            railButtons[i].toolTip = unread.map { "\(services[i].title) — \($0)" } ?? services[i].title
        }

        // Badge dock/menu bar chỉ phản ánh service đang active — không lọc thì service
        // ẩn sẽ ghi đè số của service đang xem.
        guard source === webView else { return }

        let unread = unreadBadge(from: title)

        NSApp.dockTile.badgeLabel = unread
        statusItem?.button?.title = unread.map { " \($0)" } ?? ""

        if let title, !title.isEmpty {
            // Ghép tên service: title của Facebook/Instagram không nói rõ đang ở đâu
            // khi có nhiều service.
            window?.title = services.count > 1 ? "\(activeService.title) — \(title)" : title
        }
    }

    /// Không có main menu thì ⌘C/⌘V/⌘A trong webview không hoạt động.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Thông tin bản build…", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Về trang Messenger", action: #selector(goHome), keyEquivalent: "H")
        appMenu.addItem(withTitle: "Quay lại", action: #selector(goBack), keyEquivalent: "[")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Tải lại", action: #selector(reload), keyEquivalent: "r")
        appMenu.addItem(withTitle: "Xoá HTTP cache & tải lại",
                        action: #selector(clearHTTPCache), keyEquivalent: "R")
        appMenu.addItem(withTitle: "Ẩn cửa sổ", action: #selector(hideWindow), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ẩn", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Thoát", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Sửa")
        edit.addItem(withTitle: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // Menu top-level cho dễ thấy. Dựng từ `services` (có ngay lúc init) chứ KHÔNG
        // từ `runtimes` — buildMenu() chạy trước buildUI() nên runtimes còn rỗng, đó
        // chính là lý do menu service từng không hiện.
        if services.count > 1 {
            let svcItem = NSMenuItem()
            let svc = NSMenu(title: "Service")
            for (i, service) in services.enumerated() where i < 9 {
                let item = NSMenuItem(title: service.title,
                                      action: #selector(switchService(_:)),
                                      keyEquivalent: String(i + 1))
                item.tag = i
                svc.addItem(item)
            }
            svc.addItem(.separator())
            // ⌘0 không đụng ⌘1/2/3 đang dùng để đổi kênh.
            let toggle = NSMenuItem(title: "Ẩn cột kênh", action: #selector(toggleRail), keyEquivalent: "0")
            svc.addItem(toggle)
            railMenuItem = toggle

            svcItem.submenu = svc
            main.addItem(svcItem)
            serviceMenu = svc
        }

        NSApp.mainMenu = main
        refreshServiceMenu()
    }

    /// Dấu tick vào service đang xem — không có thì không biết mình đang ở đâu.
    private func refreshServiceMenu() {
        guard let serviceMenu else { return }
        // Chỉ tick item service (tag = index). Item toggle rail có tag 0 mặc định nên
        // phải loại theo action, không thì nó cũng bị tick khi đang ở kênh đầu.
        for item in serviceMenu.items where item.action == #selector(switchService(_:)) {
            item.state = item.tag == activeIndex ? .on : .off
        }
    }

    // MARK: Ẩn/hiện — đóng là ẩn, không quit (resident ở menu bar)

    @objc private func toggle() {
        if window.isVisible && NSApp.isActive { hide() } else { showWindow() }
    }

    @objc private func hideWindow() { hide() }
    @objc private func reload() { webView.reload() }
    @objc private func goBack() { webView.goBack() }

    /// Có nút Copy vì mục đích chính của panel này là dán vào báo lỗi.
    @objc private func showAbout() {
        let text = currentVersionSummary()
        let alert = NSAlert()
        alert.messageText = "FB Mess"
        alert.informativeText = text
        alert.addButton(withTitle: "Đóng")
        alert.addButton(withTitle: "Copy")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Lưới an toàn: `⌘R` chỉ reload URL hiện tại, nên nếu bị điều hướng ra trang lạ
    /// thì không có cách nào về Messenger. Menu này load lại start URL.
    @objc private func goHome() {
        webView.load(URLRequest(url: activeService.url))
    }

    /// Xoá cache HTTP rồi tải lại.
    ///
    /// KHÔNG xoá IndexedDB: Messenger dùng E2EE (URL dạng `/e2ee/t/...`) và giữ khoá
    /// của thiết bị này trong IndexedDB. Xoá nó làm app mất device identity và lịch sử
    /// E2EE cục bộ — không phục hồi được từ server vì server không giữ bản rõ.
    @objc private func clearHTTPCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache,
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            benchLog("đã xoá HTTP cache (giữ IndexedDB/cookie) → reload")
            self?.webView.reload()
        }
    }

    private func hide() {
        if topology == .windows {
            for rt in runtimes { rt.window?.orderOut(nil) }
        }
        window.orderOut(nil)
        // Tháo webView khỏi view hierarchy để inactiveSchedulingPolicy có hiệu lực.
        guard mode.detachesWhenHidden else { return benchLog("hide: giữ webView attached") }
        if let host = webHost, webView.superview === host {
            webView.removeFromSuperview()
            benchLog("hide: detached webView khỏi rail host")
        } else if window.contentView === webView {
            window.contentView = placeholder
            benchLog("hide: detached webView (superview=\(webView.superview == nil ? "nil" : "còn"))")
        }
    }

    private func showWindow() {
        if topology == .windows {
            for rt in runtimes { rt.window?.makeKeyAndOrderFront(nil) }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let host = webHost {
            if webView.superview !== host { attachWebView(webView); benchLog("show: reattached webView") }
        } else if window.contentView !== webView {
            window.contentView = webView
            benchLog("show: reattached webView")
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    // MARK: Notification bridge

    func userContentController(_ controller: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }

        if payload["kind"] as? String == "chrome" {
            let svc = payload["service"] as? String ?? "?"
            let phase = payload["phase"] as? String ?? "?"
            let hits = payload["hits"] as? String ?? "?"
            let misses = payload["misses"] as? String ?? ""
            if misses.isEmpty {
                benchLog("[\(svc)] chrome(\(phase)): \(hits)")
            } else if phase == "early" {
                // Mốc sớm thiếu rule là bình thường với nav render trễ — chỉ log, không cảnh báo.
                benchLog("[\(svc)] chrome(early, chưa đủ): \(hits)")
            } else {
                benchLog("[\(svc)] CẢNH BÁO chrome: rule không khớp gì → [\(misses)]. "
                         + "Facebook có thể đã đổi cấu trúc hoặc ngôn ngữ UI. Chi tiết: \(hits)")
            }
            return
        }

        guard payload["kind"] as? String == "notify" else { return }

        let content = UNMutableNotificationContent()
        content.title = payload["title"] as? String ?? "Messenger"
        content.body = payload["body"] as? String ?? ""
        content.sound = .default

        let id = payload["id"] as? String ?? UUID().uuidString
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler handler: @escaping () -> Void) {
        showWindow()
        let id = response.notification.request.identifier
        webView.evaluateJavaScript("window.__mbrClick && window.__mbrClick(\(jsString(id)))")
        handler()
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler handler: @escaping (WKNavigationActionPolicy) -> Void) {
        // CHỈ chặn link user click. Redirect và form submit phải cho qua, nếu không
        // là phá luồng login — nên thắt chặt luật dưới đây không ảnh hưởng login.
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            return handler(.allow)
        }
        // Ngoài surface Messenger thì mở browser, KHÔNG giữ trong app: link facebook.com
        // trong tin nhắn từng làm app rời khỏi Messenger và không có đường về.
        if isSurface(url, of: service(for: webView)) {
            handler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            handler(.cancel)
        }
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    /// Gửi ảnh/file — không có delegate này thì nút attach im lặng không làm gì.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler handler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        handler(panel.runModal() == .OK ? panel.urls : nil)
    }

    /// Voice/video call.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler handler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.lowercased()
        let allowed = internalHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        handler(allowed ? .prompt : .deny)
    }

    // MARK: Recovery

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    /// Set thay vì Bool: với nhiều service, một flag chung khiến chỉ webview load xong
    /// đầu tiên được probe, hai service còn lại mất chẩn đoán.
    private var diagnosed = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryDelay = 2

        guard diagnosticsEnabled else { return }
        let key = ObjectIdentifier(webView)
        guard !diagnosed.contains(key) else { return }
        diagnosed.insert(key)
        let svc = service(for: webView).id

        let target = webView   // KHÔNG dùng self.webView: đó là service đang active
        target.evaluateJavaScript("navigator.userAgent") { value, _ in
            benchLog("[\(svc)] UA=\(value as? String ?? "?")")
        }
        target.evaluateJavaScript("[location.href, document.title].join(' | ')") { value, _ in
            benchLog("[\(svc)] page=\(value as? String ?? "?")")
        }

        // Probe nhiều mốc: trang có thể còn redirect hoặc chưa render list lúc didFinish.
        // Chỉ đếm element và tìm keyword trạng thái — KHÔNG đọc nội dung tin nhắn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
            target.evaluateJavaScript(navProbeJS) { value, error in
                benchLog("[\(svc)] nav=\(value as? String ?? "lỗi \(String(describing: error))")")
            }
            target.evaluateJavaScript(layoutProbeJS) { value, error in
                benchLog("[\(svc)] layout=\(value as? String ?? "lỗi \(String(describing: error))")")
            }
        }

        for delay in [10.0, 25.0, 45.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                target.evaluateJavaScript("location.href") { url, _ in
                    target.evaluateJavaScript(pageStateProbeJS) { value, error in
                        benchLog("[\(svc)] t+\(Int(delay))s url=\(url as? String ?? "?") "
                                 + "state=\(value as? String ?? "lỗi \(String(describing: error))")")
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        scheduleRetry()
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.webView.load(URLRequest(url: self.activeService.url))
        }
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--selftest") {
    runSelftest()
    exit(0)
}

// Kiểm tra máy khác đang chạy bản nào mà không cần mở GUI.
if CommandLine.arguments.contains("--version") {
    print(currentVersionSummary())
    exit(0)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
