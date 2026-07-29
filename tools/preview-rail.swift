// Render rail chọn kênh ra PNG để xem thiết kế mà không cần quyền Screen Recording.
//
//   swift tools/preview-rail.swift <out.png>
//
// Dựng ĐÚNG các control AppKit thật (NSButton + SF Symbol + NSTextField badge) rồi vẽ
// offscreen. Đây là bản dựng lại theo cùng spec, KHÔNG phải ảnh chụp app đang chạy —
// nên nó có thể lệch nếu spec trong main.swift đổi mà file này không đổi theo.

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "rail.png"

// Cùng spec với main.swift: 44x44, cornerRadius 10, rail rộng 60, spacing 8.
struct Item { let symbol: String; let tint: NSColor; let title: String; let unread: String? }
let items = [
    Item(symbol: "message.fill", tint: NSColor(srgbRed: 0.29, green: 0.52, blue: 1.0, alpha: 1),
         title: "Messenger", unread: "3"),
    Item(symbol: "camera.fill", tint: NSColor(srgbRed: 0.91, green: 0.25, blue: 0.55, alpha: 1),
         title: "Instagram", unread: nil),
    Item(symbol: "at", tint: NSColor(srgbRed: 0.34, green: 0.34, blue: 0.38, alpha: 1),
         title: "Threads", unread: "9+"),
]
let activeIndex = 0

let railWidth: CGFloat = 64
let tile: CGFloat = 48
let gap: CGFloat = 6
let height: CGFloat = 12 + CGFloat(items.count) * tile + CGFloat(items.count - 1) * gap + 12

let container = NSView(frame: NSRect(x: 0, y: 0, width: railWidth, height: height))
container.wantsLayer = true
// Nền giống vùng sidebar của macOS để đánh giá tương phản thực tế.
container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

for (i, item) in items.enumerated() {
    let y = height - 12 - CGFloat(i + 1) * tile - CGFloat(i) * gap
    let b = NSButton(frame: NSRect(x: (railWidth - tile) / 2, y: y, width: tile, height: tile))
    b.title = ""
    b.isBordered = false
    b.imagePosition = .imageOnly
    // Không set pointSize thì SF Symbol render ở cỡ mặc định, nhỏ hẳn so với ô.
    b.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)?
        .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
    b.image?.isTemplate = true
    // Glyph TRẮNG trên tile màu thương hiệu: dễ nhận hơn glyph màu trên tile xám, và
    // inactive không còn nổi hơn active.
    b.contentTintColor = NSColor.white.withAlphaComponent(i == activeIndex ? 1.0 : 0.8)
    b.wantsLayer = true
    b.layer?.cornerRadius = 12
    // Tile cho MỌI item, không chỉ active — inactive để trong suốt thì icon trông như
    // glyph rời, không ra dạng launcher.
    b.layer?.backgroundColor = item.tint.withAlphaComponent(i == activeIndex ? 1.0 : 0.45).cgColor
    if i == activeIndex {
        // Viền sáng mảnh để phân biệt active mà không đổi màu thương hiệu.
        b.layer?.borderWidth = 2
        b.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
    }
    container.addSubview(b)

    if let unread = item.unread {
        let badge = NSTextField(labelWithString: unread)
        badge.font = .systemFont(ofSize: 9.5, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 7.5
        // Badge nằm HẲN trong ô: tràn ra ngoài thì bị rail cắt mất ở mép phải.
        // Đặt ở GÓC tile, hơi tràn ra ngoài như badge iOS — rail rộng 64, tile 48 nên
        // còn 8px lề mỗi bên, tràn 4px vẫn không bị cắt.
        let w = max(15, badge.intrinsicContentSize.width + 7)
        badge.frame = NSRect(x: b.frame.maxX - w + 4, y: b.frame.maxY - 11, width: w, height: 15)
        container.addSubview(badge)
    }
}

guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
    FileHandle.standardError.write(Data("không tạo được bitmap\n".utf8)); exit(1)
}
container.cacheDisplay(in: container.bounds, to: rep)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("không encode được PNG\n".utf8)); exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("đã ghi \(outPath) (\(Int(container.bounds.width))x\(Int(container.bounds.height)))")
