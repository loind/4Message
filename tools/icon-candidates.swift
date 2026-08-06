// Dựng contact sheet các phương án icon để chọn bằng mắt, KHÔNG chọn bằng chữ.
//
//   swift tools/icon-candidates.swift <đường-dẫn-sheet.png>
//
// Mỗi ô hiện bản lớn 200px KÈM bản 48px — cỡ Dock thật. Bản lớn luôn đẹp; cỡ thật mới
// cho biết 4 chấm có sống nổi hay không. Đây là bài học từ tray icon: bolt đọc tốt ở
// zoom nhưng thành khối đen ở 18px.
//
// Giữ ràng buộc của tools/make-icon.swift: thiết kế gốc, KHÔNG dùng logo Messenger của
// Meta (trademark), KHÔNG dùng SF Symbols (license cấm làm app icon).

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-sheet.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func hex(_ s: String, _ a: CGFloat = 1) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return rgb(CGFloat((v >> 16) & 0xff), CGFloat((v >> 8) & 0xff), CGFloat(v & 0xff), a)
}
func roundedRect(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// Màu thật của 4 kênh, lấy từ electron/services.js
let serviceTints = ["#4a84ff", "#e84190", "#57575f", "#0068ff"].map { hex($0) }
let brand = hex("#4a84ff")

enum Style { case flat, depth, mono }
enum Dots { case row4, grid }

/// Bong bóng + đuôi, dùng chung mọi phương án để nhận dạng không đổi.
func bubblePath() -> CGPath {
    let bw: CGFloat = 566, bh: CGFloat = 396
    let bx = (canvas - bw) / 2, by = (canvas - bh) / 2 + 44
    let p = CGMutablePath()
    p.addPath(roundedRect(CGRect(x: bx, y: by, width: bw, height: bh), 132))
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: bx + 148, y: by + 64))
    tail.addCurve(to: CGPoint(x: bx + 84, y: by - 112),
                  control1: CGPoint(x: bx + 136, y: by - 24),
                  control2: CGPoint(x: bx + 108, y: by - 74))
    tail.addCurve(to: CGPoint(x: bx + 338, y: by + 44),
                  control1: CGPoint(x: bx + 206, y: by - 52),
                  control2: CGPoint(x: bx + 274, y: by + 34))
    tail.closeSubpath()
    p.addPath(tail)
    return p
}

/// Tâm + bán kính của 4 chấm. row4 phải nhỏ hơn để vừa bề rộng; grid được to hơn hẳn —
/// đó là toàn bộ lý do đưa grid vào so sánh.
func dotGeometry(_ d: Dots) -> ([CGPoint], CGFloat) {
    let cyBase = (canvas - 396) / 2 + 44 + 396 / 2 + 12
    switch d {
    case .row4:
        let r: CGFloat = 34, gap: CGFloat = 112
        return ((0..<4).map { CGPoint(x: canvas / 2 + (CGFloat($0) - 1.5) * gap, y: cyBase) }, r)
    case .grid:
        let r: CGFloat = 46, gap: CGFloat = 138
        var pts: [CGPoint] = []
        for row in 0..<2 { for col in 0..<2 {
            pts.append(CGPoint(x: canvas / 2 + (CGFloat(col) - 0.5) * gap,
                               y: cyBase + (0.5 - CGFloat(row)) * gap))
        } }
        return (pts, r)
    }
}

func drawIcon(_ ctx: CGContext, _ style: Style, _ dots: Dots) {
    let space = CGColorSpaceCreateDeviceRGB()
    let plate = CGRect(x: 40, y: 40, width: canvas - 80, height: canvas - 80)

    // ── Plate ──
    ctx.saveGState()
    ctx.addPath(roundedRect(plate, 208))
    ctx.clip()
    switch style {
    case .flat:
        ctx.setFillColor(brand); ctx.fill(plate)
    case .depth:
        let g = CGGradient(colorsSpace: space,
                           colors: [hex("#5B8CFF"), hex("#8B4AF6")] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 40, y: canvas - 40),
                               end: CGPoint(x: canvas - 40, y: 40), options: [])
        // Highlight kính mờ ở góc trên — xấp xỉ Liquid Glass bằng radial gradient.
        let sheen = CGGradient(colorsSpace: space,
                               colors: [rgb(255, 255, 255, 0.42), rgb(255, 255, 255, 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 330, y: 830), startRadius: 0,
                               endCenter: CGPoint(x: 330, y: 830), endRadius: 560, options: [])
    case .mono:
        ctx.setFillColor(hex("#2B3A67")); ctx.fill(plate)
    }
    ctx.restoreGState()

    // Viền trong mảnh: tách icon khỏi nền sáng của Dock.
    ctx.addPath(roundedRect(plate.insetBy(dx: 1.5, dy: 1.5), 207))
    ctx.setStrokeColor(rgb(255, 255, 255, style == .mono ? 0.16 : 0.28))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // ── Bong bóng ──
    let body = bubblePath()
    ctx.saveGState()
    if style == .depth {
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(20, 30, 90, 0.28))
    }
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.addPath(body); ctx.fillPath()
    ctx.restoreGState()

    // ── 4 chấm ──
    let (pts, r) = dotGeometry(dots)
    for (i, c) in pts.enumerated() {
        let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        switch style {
        case .flat:
            // Mỗi chấm một màu kênh: 4 chấm = 4 kênh, nói được ý nghĩa của tên.
            ctx.setFillColor(serviceTints[i])
            ctx.addEllipse(in: box); ctx.fillPath()
        case .depth:
            ctx.saveGState()
            ctx.addEllipse(in: box); ctx.clip()
            let g = CGGradient(colorsSpace: space,
                               colors: [serviceTints[i], hex("#8B4AF6")] as CFArray,
                               locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: box.minX, y: box.maxY),
                                   end: CGPoint(x: box.maxX, y: box.minY), options: [])
            ctx.restoreGState()
        case .mono:
            // Khoét lỗ: chấm lấy đúng màu plate, glyph còn lại trắng tinh — cùng hình
            // với tray icon nên hai asset khớp tuyệt đối.
            ctx.setBlendMode(.destinationOut)
            ctx.addEllipse(in: box); ctx.fillPath()
            ctx.setBlendMode(.normal)
        }
    }
}

func render(_ style: Style, _ dots: Dots, size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    // mono khoét lỗ bằng destinationOut nên cần plate vẽ trước trên nền trong suốt.
    drawIcon(ctx, style, dots)
    return ctx.makeImage()
}

// ── Contact sheet ──
let cases: [(String, Style, Dots)] = [
    ("1  flat · hàng 4", .flat, .row4),   ("2  flat · 2×2", .flat, .grid),
    ("3  depth · hàng 4", .depth, .row4), ("4  depth · 2×2", .depth, .grid),
    ("5  mono · hàng 4", .mono, .row4),   ("6  mono · 2×2", .mono, .grid),
]
let big = 200, small = 48, padX = 26, padY = 22, cellW = 200 + 24 + 48 + 40, cellH = 200 + 44
let sheetW = padX * 2 + cellW * 2, sheetH = padY * 2 + cellH * 3 + 30

let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(rgb(242, 242, 245)); ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ns

for (i, c) in cases.enumerated() {
    let col = i % 2, row = i / 2
    let x = padX + col * cellW
    let y = sheetH - padY - 30 - (row + 1) * cellH + 30
    if let img = render(c.1, c.2, size: big * 2) {
        ctx.draw(img, in: CGRect(x: x, y: y, width: big, height: big))
    }
    if let img = render(c.1, c.2, size: small * 2) {
        // Cỡ Dock thật, đặt cạnh bản lớn để so trực tiếp.
        ctx.draw(img, in: CGRect(x: x + big + 24, y: y + big - small, width: small, height: small))
    }
    (c.0 as NSString).draw(at: NSPoint(x: x, y: y - 22),
        withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.black])
    ("48px" as NSString).draw(at: NSPoint(x: x + big + 24, y: y + big - small - 18),
        withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: NSColor.darkGray])
}
("4 chấm — bản lớn 200px và cỡ Dock thật 48px" as NSString)
    .draw(at: NSPoint(x: padX, y: sheetH - 26),
          withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold),
                           .foregroundColor: NSColor.black])
NSGraphicsContext.restoreGraphicsState()

let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("sheet: \(out)  (\(sheetW)×\(sheetH))")
