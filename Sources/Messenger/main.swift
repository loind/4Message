import AppKit
import Carbon.HIToolbox
import UserNotifications
import WebKit

/// Mốc đo khởi động. Khai báo đầu tiên để chạy sớm nhất trong top-level code.
/// Không tính được phần dyld load trước `main` — phần đó đo từ shell (`startup.sh`).
let launchClock = Date()

/// Host được phép mở trong app; còn lại đẩy sang browser mặc định.
let internalHosts = ["messenger.com", "facebook.com", "fbcdn.net", "fb.com", "m.me"]

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

/// Link user CLICK có được giữ trong app hay không — khác hẳn `isInternal`.
///
/// `isInternal` trả lời "host nào được phép LOAD", và buộc phải chứa cả `facebook.com`
/// vì luồng login redirect qua đó. Dùng chính nó để quyết định link click là sai: mọi
/// link facebook.com trong tin nhắn (post, ảnh, page, reel) sẽ điều hướng app rời khỏi
/// Messenger, và app không có đường về nên trông như bị treo.
///
/// Hàm này chỉ nhận đúng surface Messenger.
func isMessengerSurface(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    let matches = { (domain: String) in host == domain || host.hasSuffix("." + domain) }

    if matches("messenger.com") || matches("m.me") { return true }
    if matches("facebook.com") {
        let path = url.path
        // Khớp chính xác `/messages` hoặc có `/` sau — để `/messagesfake` không lọt.
        return path == "/messages" || path.hasPrefix("/messages/")
    }
    return false
}

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
    check(isMessengerSurface(URL(string: "https://www.facebook.com/messages/")!), "fb /messages/")
    check(isMessengerSurface(URL(string: "https://www.facebook.com/messages")!), "fb /messages")
    check(isMessengerSurface(URL(string: "https://www.facebook.com/messages/e2ee/t/1")!), "fb thread")
    check(isMessengerSurface(URL(string: "https://www.messenger.com/t/1")!), "messenger.com")
    check(isMessengerSurface(URL(string: "https://m.me/abc")!), "m.me")
    // Đây là bug đã gây treo: link content facebook.com phải ra browser.
    check(!isMessengerSurface(URL(string: "https://www.facebook.com/facebook")!), "fb page → browser")
    check(!isMessengerSurface(URL(string: "https://www.facebook.com/photo/?fbid=1")!), "fb photo → browser")
    check(!isMessengerSurface(URL(string: "https://www.facebook.com/reel/1")!), "fb reel → browser")
    check(!isMessengerSurface(URL(string: "https://www.facebook.com/messagesfake")!), "prefix giả không lọt")
    check(!isMessengerSurface(URL(string: "https://evil-facebook.com/messages/")!), "host giả mạo")
    check(!isMessengerSurface(URL(string: "https://youtube.com/watch")!), "host ngoài")

    check(jsString("a\"b") == "\"a\\\"b\"", "escape JS string")

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

    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var hotkey: Hotkey?
    private var titleObserver: NSKeyValueObservation?
    private var activity: NSObjectProtocol?
    private var retryDelay: TimeInterval = 2

    /// Chỗ giữ contentView khi webView bị tháo ra (contentView không được nil).
    private lazy var placeholder = NSView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        benchLog("mode=\(mode.rawValue) policy=\(mode.schedulingPolicy.rawValue) "
                 + "detach=\(mode.detachesWhenHidden) assertion=\(mode.holdsAwakeAssertion) "
                 + "block=\(mode.blocksTelemetryAndMedia) hideAfter=\(benchHideAfter)")

        buildMenu()
        buildWindow()
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

        loadMessenger()

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

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent → login sống qua restart

        // UA mặc định của WKWebView thiếu token `Version/... Safari/...`:
        //   Mozilla/5.0 (Macintosh; ...) AppleWebKit/605.1.15 (KHTML, like Gecko)
        // Facebook sniff UA, thiếu token này dễ bị serve bundle client hạn chế.
        // `applicationNameForUserAgent` được WebKit ghép vào cuối UA mặc định →
        // ra đúng format Safari. Bump khi Safari lên version mới.
        config.applicationNameForUserAgent = safariUserAgentSuffix
        config.preferences.inactiveSchedulingPolicy = mode.schedulingPolicy
        config.userContentController.add(self, name: "mbr")
        config.userContentController.addUserScript(
            WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // Kill switch: nếu selector khớp nhầm và app thành không dùng được thì
        // `FBMESS_KEEP_FB_CHROME=1` để tắt, không cần rebuild.
        if ProcessInfo.processInfo.environment["FBMESS_KEEP_FB_CHROME"] != "1" {
            config.userContentController.addUserScript(
                WKUserScript(source: hideChromeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Bật lại: nếu có navigation nào lọt qua luật link thì user vẫn thoát được,
        // không bị kẹt trên trang lạ.
        webView.allowsBackForwardNavigationGestures = true

        titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            self?.applyTitle(webView.title)
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Messenger"
        window.minSize = NSSize(width: 420, height: 400)
        window.contentView = webView
        window.delegate = self
        window.setFrameAutosaveName("MessengerMain")
        if !window.setFrameUsingName("MessengerMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func loadMessenger() {
        guard mode.blocksTelemetryAndMedia else {
            webView.load(URLRequest(url: messengerURL))
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "fbmess-block",
            encodedContentRuleList: blockRulesJSON
        ) { [weak self] list, error in
            guard let self else { return }
            if let list {
                self.webView.configuration.userContentController.add(list)
                benchLog("content rule list đã áp dụng")
            } else {
                benchLog("content rule compile FAILED: \(String(describing: error))")
            }
            self.webView.load(URLRequest(url: messengerURL))
        }
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
    private func applyTitle(_ title: String?) {
        let unread = unreadBadge(from: title)

        NSApp.dockTile.badgeLabel = unread
        statusItem?.button?.title = unread.map { " \($0)" } ?? ""

        if let title, !title.isEmpty {
            window?.title = title
        }
    }

    /// Không có main menu thì ⌘C/⌘V/⌘A trong webview không hoạt động.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Về Messenger", action: #selector(goHome), keyEquivalent: "H")
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

        NSApp.mainMenu = main
    }

    // MARK: Ẩn/hiện — đóng là ẩn, không quit (resident ở menu bar)

    @objc private func toggle() {
        if window.isVisible && NSApp.isActive { hide() } else { showWindow() }
    }

    @objc private func hideWindow() { hide() }
    @objc private func reload() { webView.reload() }
    @objc private func goBack() { webView.goBack() }

    /// Lưới an toàn: `⌘R` chỉ reload URL hiện tại, nên nếu bị điều hướng ra trang lạ
    /// thì không có cách nào về Messenger. Menu này load lại start URL.
    @objc private func goHome() {
        webView.load(URLRequest(url: messengerURL))
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
        window.orderOut(nil)
        // Tháo webView khỏi view hierarchy để inactiveSchedulingPolicy có hiệu lực.
        if mode.detachesWhenHidden, window.contentView === webView {
            window.contentView = placeholder
            benchLog("hide: detached webView (superview=\(webView.superview == nil ? "nil" : "còn"))")
        } else {
            benchLog("hide: giữ webView attached")
        }
    }

    private func showWindow() {
        if window.contentView !== webView {
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
            let hits = payload["hits"] as? String ?? "?"
            let misses = payload["misses"] as? String ?? ""
            if misses.isEmpty {
                benchLog("chrome: \(hits)")
            } else {
                benchLog("CẢNH BÁO chrome: rule không khớp gì → [\(misses)]. "
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
        if isMessengerSurface(url) {
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

    private var loggedDiagnostics = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryDelay = 2

        guard diagnosticsEnabled, !loggedDiagnostics else { return }
        loggedDiagnostics = true

        webView.evaluateJavaScript("navigator.userAgent") { value, _ in
            benchLog("UA=\(value as? String ?? "?")")
        }
        webView.evaluateJavaScript("[location.href, document.title].join(' | ')") { value, _ in
            benchLog("page=\(value as? String ?? "?")")
        }

        // Probe nhiều mốc: trang có thể còn redirect hoặc chưa render list lúc didFinish.
        // Chỉ đếm element và tìm keyword trạng thái — KHÔNG đọc nội dung tin nhắn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            self?.webView.evaluateJavaScript(navProbeJS) { value, error in
                benchLog("nav=\(value as? String ?? "lỗi \(String(describing: error))")")
            }
        }

        for delay in [10.0, 25.0, 45.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView.evaluateJavaScript("location.href") { url, _ in
                    self?.webView.evaluateJavaScript(pageStateProbeJS) { value, error in
                        benchLog("t+\(Int(delay))s url=\(url as? String ?? "?") "
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
            self.webView.load(URLRequest(url: messengerURL))
        }
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--selftest") {
    runSelftest()
    exit(0)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
