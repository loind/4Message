import AppKit

/// Rail chọn kênh — **một nguồn duy nhất** cho cả app và `tools/preview-rail.swift`.
///
/// Trước đây preview dựng lại bằng frame thủ công nên luôn có khoảng cách giữa các tile,
/// còn app dựng bằng NSStackView. Hai code path khác nhau ⇒ preview không thể phát hiện
/// lỗi layout của app, và đã bỏ sót đúng lỗi tile dính liền nhau. Giờ cả hai gọi hàm này.
/// NSButton có `alignmentRectInsets` khác 0 (đo được top 6 / bottom 4, thay đổi theo
/// symbol). Auto Layout ràng buộc ALIGNMENT RECT chứ không phải frame, nên
/// `height = 48` cho ra frame 48+6+4 = 58; còn layer — thứ thực sự được vẽ — dùng frame.
/// Hệ quả: tile to hơn khai báo và `gap = 10` bị insets ăn còn 1px, tile trông dính liền.
/// Ép insets về 0 để frame trùng alignment rect.
private final class RailButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

struct RailBuild {
    let view: NSView
    let buttons: [NSButton]
    let badges: [NSTextField]
}

enum Rail {
    static let width: CGFloat = 68
    static let tile: CGFloat = 48
    static let gap: CGFloat = 10

    /// Layout bằng constraint chain tường minh, KHÔNG dùng NSStackView.
    ///
    /// Đã thử NSStackView và nó bỏ qua cả `spacing`, `edgeInsets` lẫn ràng buộc
    /// `height = 48` của tile: đo ra tile cao 58/57/59, khoảng cách 1px, inset 6px — dù
    /// constraint height vẫn active ở priority 1000. Chain tường minh thì đo đúng bằng
    /// số đã khai báo, không phải đoán xem stack sẽ phân phối thế nào.
    static func make(services: [Service], target: AnyObject?, action: Selector?) -> RailBuild {
        let root = NSView()

        var buttons: [NSButton] = []
        var badges: [NSTextField] = []

        for (i, service) in services.enumerated() {
            let b = RailButton(frame: .zero)
            b.tag = i
            b.target = target
            b.action = action
            b.title = ""
            b.isBordered = false
            b.imagePosition = .imageOnly
            // Không set pointSize thì SF Symbol render ở cỡ mặc định, nhỏ hẳn so với tile.
            b.image = NSImage(systemSymbolName: service.symbol, accessibilityDescription: service.title)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            b.image?.isTemplate = true
            b.toolTip = service.title
            // Label đặt thẳng trên nút: `.withSymbolConfiguration(...)` trả về image mới
            // và làm mất accessibilityDescription, nút icon-only sẽ không có label.
            b.setAccessibilityLabel(service.title)
            b.wantsLayer = true
            b.layer?.cornerRadius = 12
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: tile).isActive = true
            b.heightAnchor.constraint(equalToConstant: tile).isActive = true

            let badge = NSTextField(labelWithString: "")
            badge.font = .systemFont(ofSize: 9.5, weight: .bold)
            badge.textColor = .white
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.systemRed.cgColor
            badge.layer?.cornerRadius = 7.5
            badge.isHidden = true
            badge.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(badge)
            // NẰM HẲN trong tile. Hai bản trước cho tràn ra ngoài và cả hai lần đều bị
            // mép rail cắt mất — không đáng đổi lấy vẻ "badge iOS".
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -2),
                badge.topAnchor.constraint(equalTo: b.topAnchor, constant: 2),
                badge.heightAnchor.constraint(equalToConstant: 15),
                badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 15),
            ])

            root.addSubview(b)
            b.centerXAnchor.constraint(equalTo: root.centerXAnchor).isActive = true
            // Chain: tile đầu cách đỉnh 12, các tile sau cách tile trước đúng `gap`.
            if let prev = buttons.last {
                b.topAnchor.constraint(equalTo: prev.bottomAnchor, constant: gap).isActive = true
            } else {
                b.topAnchor.constraint(equalTo: root.topAnchor, constant: 12).isActive = true
            }
            buttons.append(b)
            badges.append(badge)
        }

        if let last = buttons.last {
            root.bottomAnchor.constraint(equalTo: last.bottomAnchor, constant: 12).isActive = true
        }
        root.widthAnchor.constraint(equalToConstant: width).isActive = true

        return RailBuild(view: root, buttons: buttons, badges: badges)
    }

    /// Màu phải ĐỤC, không dùng alpha: alpha phủ lên nền không biết trước nên ở light mode
    /// tile nhạt toẹt còn inactive lại nổi hơn active. Bản trước chỉ được kiểm tra ở dark.
    static func style(_ build: RailBuild, services: [Service], activeIndex: Int) {
        for (i, b) in build.buttons.enumerated() {
            let active = i == activeIndex
            let tint = services[i].tint
            b.layer?.backgroundColor = active
                ? tint.cgColor
                : (tint.blended(withFraction: 0.55, of: .systemGray) ?? tint).cgColor
            b.contentTintColor = .white
            b.layer?.borderWidth = active ? 2.5 : 0
            b.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.75).cgColor
        }
    }
}
