import AppKit
import Foundation

/// Một host thuộc surface của service, kèm path prefix bắt buộc.
///
/// Prefix phải gắn với HOST chứ không phải service: `facebook.com` chỉ có `/messages` là
/// chat (còn lại là feed), nhưng `messenger.com` và `m.me` thì cả domain đều là chat.
/// Đặt prefix ở cấp service làm `messenger.com/t/<id>` bị từ chối — selftest bắt được.
struct SurfaceRule: Equatable {
    let host: String
    let pathPrefix: String   // rỗng = nhận mọi path

    init(_ host: String, _ pathPrefix: String = "") {
        self.host = host
        self.pathPrefix = pathPrefix
    }
}

/// Một phần chrome cần ẩn. `name` chỉ để self-check báo rule nào khớp 0 element.
struct HideRule: Equatable {
    let name: String
    let selector: String
    init(_ name: String, _ selector: String) { self.name = name; self.selector = selector }
}

/// Một service được wrap. Mỗi service là một origin riêng → cookie, IndexedDB, và
/// device E2EE riêng biệt. Không chia sẻ gì với nhau.
struct Service: Equatable {
    let id: String
    let title: String
    let url: URL
    /// Link user click nằm ngoài các rule này → mở browser, không giữ trong app.
    /// Tách theo service để link Instagram không mở trong cửa sổ Messenger.
    let surface: [SurfaceRule]
    /// CSS ẩn chrome. Phải riêng từng service: DOM của Facebook và Instagram khác nhau
    /// hoàn toàn, dùng chung selector là ẩn nhầm hoặc không ẩn được gì.
    let hideRules: [HideRule]
    /// SF Symbol cho rail. Dùng SF Symbols vì license cho phép trong UI (chỉ cấm làm
    /// app icon/logo) — khác với logo thương hiệu của Meta.
    let symbol: String
    let tint: NSColor
}

// Threads DM nằm ở `/messages/`, KHÔNG phải `/direct/`. Suy diễn theo Instagram là sai:
// `/direct` và `/direct/inbox` redirect về feed, nên tôi từng kết luận web Threads không
// có DM. Soi DOM mới thấy nav có `/messages/`.
let knownServices: [Service] = [
    Service(id: "messenger",
            title: "Messenger",
            url: URL(string: "https://www.facebook.com/messages/")!,
            surface: [SurfaceRule("facebook.com", "/messages"),
                      SurfaceRule("messenger.com"),
                      SurfaceRule("m.me")],
            // Nhận thanh tab theo href nên độc lập ngôn ngữ; ba rule còn lại chỉ phân
            // biệt được qua aria-label nên KHỚP CHÍNH XÁC — match kiểu `*=` từng trúng
            // cả một tin nhắn, vì nội dung tin nhắn cũng vào aria-label.
            hideRules: [
                HideRule("tab bar", #"[role="navigation"]:has(a[href^="/marketplace/"])"#),
                HideRule("search input", #"input[aria-label="Search Facebook"]"#),
                // Ẩn <input> thôi chưa đủ: nút tròn nhìn thấy được là <label> bọc ngoài.
                // BẮT BUỘC có `> input` — thiếu dấu `>` thì khớp mọi ancestor tới <body>.
                HideRule("search button", #"*:has(> input[aria-label="Search Facebook"])"#),
                HideRule("typeahead x", #"[role="button"][aria-label="Exit typeahead"]"#),
                HideRule("facebook menu", #"[role="button"][aria-label="Facebook menu"]"#),
            ],
            symbol: "message.fill",
            tint: NSColor(srgbRed: 0.29, green: 0.52, blue: 1.0, alpha: 1)),
    Service(id: "instagram",
            title: "Instagram",
            url: URL(string: "https://www.instagram.com/direct/inbox/")!,
            surface: [SurfaceRule("instagram.com", "/direct")],
            // Rail bên trái nằm NGOÀI `[role="navigation"]` — trên Instagram role đó là
            // panel danh sách hội thoại (dòng chat 362x72). Nhắm vào nó là xoá sạch chat.
            // Nên nhận theo href, độc lập ngôn ngữ và độc lập tài khoản.
            // Không ẩn link profile: path chứa username nên không hardcode được.
            hideRules: [
                HideRule("home", #"a[href="/"]"#),
                HideRule("reels", #"a[href^="/reels/"]"#),
                HideRule("explore", #"a[href^="/explore/"]"#),
            ],
            symbol: "camera.fill",
            tint: NSColor(srgbRed: 0.91, green: 0.25, blue: 0.55, alpha: 1)),
    Service(id: "threads",
            title: "Threads",
            url: URL(string: "https://www.threads.com/")!,
            // Cả domain, KHÔNG chỉ /messages: kênh này xem feed nên bài viết, profile,
            // search đều phải ở lại trong app. Giới hạn /messages làm mọi bài trong feed
            // bật ra Safari.
            surface: [SurfaceRule("threads.com"),
                      SurfaceRule("threads.net")],
            // Cố tình rỗng. Nav của Threads là đường DUY NHẤT đi giữa feed và DM
            // (app không có tab riêng cho hai chỗ đó) — ẩn logo/search/activity là khoá
            // luôn đường về feed sau khi vào tin nhắn.
            hideRules: [],
            symbol: "at",
            tint: NSColor(srgbRed: 0.34, green: 0.34, blue: 0.38, alpha: 1)),
    // Zalo KHÔNG phải của Meta — service đầu tiên như vậy. Đo bằng probe (2026-08-04):
    // chat.zalo.me redirect sang id.zalo.me/account?continue=… khi chưa login, QR render
    // bình thường, không có màn "trình duyệt không hỗ trợ".
    // CHƯA kiểm chứng được (cần tài khoản đã login): Zalo có ghi số chưa đọc vào
    // `document.title` kiểu `(3) …` hay không. Nếu không thì badge rail của Zalo luôn rỗng
    // và phải đọc số bằng cách khác — xem README.
    Service(id: "zalo",
            title: "Zalo",
            url: URL(string: "https://chat.zalo.me/")!,
            // Cả chat và id: id.zalo.me là màn login, thiếu nó thì link trên trang login bị
            // đẩy ra browser giữa luồng đăng nhập. KHÔNG mở cả zalo.me — profile và bài
            // viết công khai nằm ở đó, giữ trong app là lặp lại bug link facebook.com.
            surface: [SurfaceRule("chat.zalo.me"),
                      SurfaceRule("id.zalo.me")],
            // Zalo Web chỉ có chat, không có feed để tách khỏi chrome.
            hideRules: [],
            symbol: "bubble.left.and.bubble.right.fill",
            tint: NSColor(srgbRed: 0.0, green: 0.41, blue: 1.0, alpha: 1)),
]

/// Cấu hình bằng `FBMESS_SERVICES=messenger,instagram`. Mặc định chỉ messenger để
/// hành vi hiện tại không đổi.
func resolveServices(_ raw: String?) -> [Service] {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
        return [knownServices[0]]
    }
    let wanted = raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }

    // Giữ thứ tự user viết, bỏ id không biết, loại trùng.
    var seen = Set<String>()
    let picked = wanted.compactMap { id -> Service? in
        guard !seen.contains(id), let s = knownServices.first(where: { $0.id == id }) else { return nil }
        seen.insert(id)
        return s
    }
    return picked.isEmpty ? [knownServices[0]] : picked
}

/// `tabs` = 1 cửa sổ, đổi webview. `windows` = mỗi service 1 cửa sổ.
enum Topology: String {
    case tabs, windows

    static func resolve(_ raw: String?) -> Topology {
        Topology(rawValue: (raw ?? "").lowercased()) ?? .tabs
    }
}

/// Link user click có thuộc surface của service này không.
///
/// Thay cho `isMessengerSurface` cũ vốn hardcode Messenger. Cùng nguyên tắc: chỉ giữ
/// trong app khi đúng surface, còn lại đẩy sang browser — trước đây link facebook.com
/// trong tin nhắn đã làm app rời khỏi Messenger và không có đường về.
func isSurface(_ url: URL, of service: Service) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    let path = url.path

    return service.surface.contains { rule in
        guard host == rule.host || host.hasSuffix("." + rule.host) else { return false }
        guard !rule.pathPrefix.isEmpty else { return true }
        // Khớp chính xác prefix hoặc có `/` ngay sau — để `/messagesfake` không lọt.
        return path == rule.pathPrefix || path.hasPrefix(rule.pathPrefix + "/")
    }
}
