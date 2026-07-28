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

/// Một service được wrap. Mỗi service là một origin riêng → cookie, IndexedDB, và
/// device E2EE riêng biệt. Không chia sẻ gì với nhau.
struct Service: Equatable {
    let id: String
    let title: String
    let url: URL
    /// Link user click nằm ngoài các rule này → mở browser, không giữ trong app.
    /// Tách theo service để link Instagram không mở trong cửa sổ Messenger.
    let surface: [SurfaceRule]
}

let knownServices: [Service] = [
    Service(id: "messenger",
            title: "Messenger",
            url: URL(string: "https://www.facebook.com/messages/")!,
            surface: [SurfaceRule("facebook.com", "/messages"),
                      SurfaceRule("messenger.com"),
                      SurfaceRule("m.me")]),
    Service(id: "instagram",
            title: "Instagram",
            url: URL(string: "https://www.instagram.com/direct/inbox/")!,
            surface: [SurfaceRule("instagram.com", "/direct")]),
    Service(id: "threads",
            title: "Threads",
            url: URL(string: "https://www.threads.com/")!,
            surface: [SurfaceRule("threads.com"), SurfaceRule("threads.net")]),
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
