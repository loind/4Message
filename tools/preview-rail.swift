// Render rail chọn kênh ra PNG để xem thiết kế mà không cần quyền Screen Recording.
//
//   ./preview-rail.sh out.png
//
// Dùng ĐÚNG `Rail.make` mà app dùng, KHÔNG dựng lại. Bản trước dựng lại bằng frame thủ
// công nên luôn có khoảng cách giữa tile, che mất đúng lỗi tile dính liền của app.
//
// Render CẢ light VÀ dark cạnh nhau: bản trước chỉ render một appearance (dark mặc định
// của process) nên thiết kế nhạt toẹt ở light mode mà không phát hiện được.

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "rail.png"
let services = knownServices              // đúng danh sách app dùng
let unread: [String?] = ["3", nil, "9+"]  // giả lập để thấy badge
let activeIndex = 0

func renderRail(appearance: NSAppearance) -> NSBitmapImageRep {
    let build = Rail.make(services: services, target: nil, action: nil)
    for (i, u) in unread.enumerated() where i < build.badges.count {
        build.badges[i].stringValue = u ?? ""
        build.badges[i].isHidden = (u == nil)
    }

    let height = 12 + CGFloat(services.count) * Rail.tile
        + CGFloat(max(0, services.count - 1)) * Rail.gap + 12
    let container = NSView(frame: NSRect(x: 0, y: 0, width: Rail.width, height: height))
    container.appearance = appearance
    container.wantsLayer = true

    let stack: NSView = build.view
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        // KHÔNG pin bottom — pin cả hai là stack bị giãn và mất spacing.
    ])
    container.layoutSubtreeIfNeeded()

    // In frame thật: đoán layout đã sai 2 lần, phải đo.
    FileHandle.standardError.write(Data("appearance=\(appearance.name.rawValue) container=\(container.frame.size)\n".utf8))
    FileHandle.standardError.write(Data("  stack frame=\(stack.frame)\n".utf8))
    for (i, b) in build.buttons.enumerated() {
        FileHandle.standardError.write(Data("  tile[\(i)] frame=\(b.frame) layer=\(b.layer?.bounds ?? .zero) fitting=\(b.fittingSize) alignRect=\(b.alignmentRectInsets)\n".utf8))
        FileHandle.standardError.write(Data("      intrinsic=\(b.intrinsicContentSize)\n".utf8))
    }

    let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
    // Màu semantic (windowBackgroundColor, labelColor) và tile phải resolve BÊN TRONG
    // block này. Set `.cgColor` bên ngoài là nó chốt theo appearance hiện tại của
    // process — bản "dark" render ra y hệt bản light, so sánh thành vô nghĩa.
    appearance.performAsCurrentDrawingAppearance {
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        Rail.style(build, services: services, activeIndex: activeIndex)
        container.cacheDisplay(in: container.bounds, to: rep)
    }
    return rep
}

let light = renderRail(appearance: NSAppearance(named: .aqua)!)
let dark = renderRail(appearance: NSAppearance(named: .darkAqua)!)

// Ghép ngang: light | dark, cách nhau 12px để phân biệt.
let pad: CGFloat = 12
let w = CGFloat(light.pixelsWide) + pad + CGFloat(dark.pixelsWide)
let h = max(CGFloat(light.pixelsHigh), CGFloat(dark.pixelsHigh))
let combined = NSImage(size: NSSize(width: w, height: h))
combined.lockFocus()
NSColor.systemGray.setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()
light.draw(in: NSRect(x: 0, y: 0, width: CGFloat(light.pixelsWide), height: CGFloat(light.pixelsHigh)))
dark.draw(in: NSRect(x: CGFloat(light.pixelsWide) + pad, y: 0,
                     width: CGFloat(dark.pixelsWide), height: CGFloat(dark.pixelsHigh)))
combined.unlockFocus()

guard let tiff = combined.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("không encode được PNG\n".utf8)); exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("đã ghi \(outPath) — trái = light, phải = dark (\(Int(w))x\(Int(h)))")
