// Vòng 2: đuôi sửa lại, nudge dọc theo số đo, 3 phương án màu, kèm tray đơn sắc.
//
//   swift tools/icon-v2.swift <thư-mục-out>
//
// Đuôi vẽ bằng tam giác TRÒN GÓC (addArc tangent) chứ không phải bezier đoán tay — vòng 1
// đoán control point và ra cái gai nhọn. Tròn góc thì hình đúng theo dựng hình, không theo
// cảm giác.
//
// Giữ ràng buộc: thiết kế gốc, KHÔNG logo Meta (trademark), KHÔNG SF Symbols (license).

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build-icon"

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

let plate = CGRect(x: 40, y: 40, width: canvas - 80, height: canvas - 80)
let bubbleW: CGFloat = 470, bubbleH: CGFloat = 404, corner: CGFloat = 128
let dotR: CGFloat = 46, dotGap: CGFloat = 132
let tailH: CGFloat = 78, tipR: CGFloat = 20
// Đuôi thò xuống tailH nên toàn khối chìm; nâng nửa chiều đuôi để bbox cân trở lại.
let nudgeY: CGFloat = 16   // đo được: 39 làm bbox cao 18 và centroid +34

func bubbleRect() -> CGRect {
    CGRect(x: (canvas - bubbleW) / 2, y: (canvas - bubbleH) / 2 + nudgeY,
           width: bubbleW, height: bubbleH)
}

func bubblePath() -> CGPath {
    let b = bubbleRect()
    let p = CGMutablePath()
    p.addPath(roundedRect(b, corner))
    // Tam giác tròn góc, neo trên mép dưới, chĩa xuống-trái.
    let ax = b.minX + corner * 0.58
    let t = CGMutablePath()
    t.move(to: CGPoint(x: ax, y: b.minY + 6))
    t.addArc(tangent1End: CGPoint(x: ax - 66, y: b.minY - tailH),
             tangent2End: CGPoint(x: ax + 104, y: b.minY + 6), radius: tipR)
    t.addLine(to: CGPoint(x: ax + 104, y: b.minY + 6))
    t.closeSubpath()
    p.addPath(t)
    return p
}

func dotCenters() -> [CGPoint] {
    let b = bubbleRect()
    var pts: [CGPoint] = []
    for row in 0..<2 { for col in 0..<2 {
        pts.append(CGPoint(x: b.midX + (CGFloat(col) - 0.5) * dotGap,
                           y: b.midY + (0.5 - CGFloat(row)) * dotGap))
    } }
    return pts
}

enum Palette: Int { case indigoPlate = 0, tealZalo = 1, monoDots = 2 }
func plateColor(_ p: Palette) -> CGColor {
    switch p {
    case .indigoPlate: return hex("#2F3E9E")
    case .tealZalo, .monoDots: return hex("#4a84ff")
    }
}
func dotColors(_ p: Palette) -> [CGColor] {
    switch p {
    // Màu thương hiệu thật của 4 kênh; plate indigo nên cả bốn đều đọc được.
    case .indigoPlate: return ["#4a84ff", "#e84190", "#57575f", "#0068ff"].map { hex($0) }
    // Giữ plate xanh, đổi zalo sang teal cho tách khỏi messenger.
    case .tealZalo:    return ["#4a84ff", "#e84190", "#57575f", "#12b3a8"].map { hex($0) }
    // Chấm cùng màu plate → đọc như lỗ khoét, khớp hình với tray đơn sắc.
    case .monoDots:    return Array(repeating: hex("#4a84ff"), count: 4)
    }
}

func drawApp(_ ctx: CGContext, _ pal: Palette, border: Bool = true) {
    ctx.saveGState()
    ctx.addPath(roundedRect(plate, 208)); ctx.clip()
    ctx.setFillColor(plateColor(pal)); ctx.fill(plate)
    ctx.restoreGState()
    if border {
        ctx.addPath(roundedRect(plate.insetBy(dx: 1.5, dy: 1.5), 207))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.26)); ctx.setLineWidth(3); ctx.strokePath()
    }
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.addPath(bubblePath()); ctx.fillPath()
    for (i, c) in dotCenters().enumerated() {
        ctx.setFillColor(dotColors(pal)[i])
        ctx.addEllipse(in: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2))
        ctx.fillPath()
    }
}

/// Tray: template image, chỉ đen + alpha. Chấm là LỖ THẬT (destinationOut) vì macOS chỉ
/// đọc alpha — vẽ chấm màu trắng sẽ thành khối trắng khi menu bar đảo màu.
func drawTray(_ ctx: CGContext, white: Bool = false) {
    // Scale glyph cho bbox tràn khung, chỉ chừa lề mảnh. KHÔNG tái dùng tỉ lệ app icon:
    // app có plate nên bubble chỉ chiếm ~46% khung, còn tray không có plate — giữ tỉ lệ đó
    // thì ở 20px bubble chỉ ~9px và bốn chấm biến mất.
    let bb = bubblePath().boundingBox
    let pad: CGFloat = 26
    let k = min((canvas - pad * 2) / bb.width, (canvas - pad * 2) / bb.height)
    ctx.saveGState()
    ctx.translateBy(x: (canvas - bb.width * k) / 2 - bb.minX * k,
                    y: (canvas - bb.height * k) / 2 - bb.minY * k)
    ctx.scaleBy(x: k, y: k)
    ctx.setFillColor(white ? rgb(255, 255, 255) : rgb(0, 0, 0))
    ctx.addPath(bubblePath()); ctx.fillPath()
    ctx.setBlendMode(.destinationOut)
    for c in dotCenters() {
        ctx.addEllipse(in: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2))
        ctx.fillPath()
    }
    ctx.setBlendMode(.normal)
    ctx.restoreGState()
}

func render(_ size: Int, _ body: (CGContext) -> Void) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    body(ctx)
    return ctx.makeImage()
}

// ── Đo cân bằng (chỉ pixel alpha ĐẦY và khác màu plate) ──
func balance(_ pal: Palette) -> (Double, Double, Double, Double, Double, Double) {
    let S = 512
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(S) / canvas, y: CGFloat(S) / canvas)
    drawApp(ctx, pal, border: false)
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: S * S * 4)
    let pc = plateColor(pal).components!.map { UInt8(($0 * 255).rounded()) }
    var cx = 0.0, cy = 0.0, n = 0.0, minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9
    for y in 4..<(S - 4) { for x in 4..<(S - 4) {
        let o = (y * S + x) * 4
        if px[o+3] < 250 { continue }
        if abs(Int(px[o]) - Int(pc[0])) < 14 && abs(Int(px[o+1]) - Int(pc[1])) < 14
            && abs(Int(px[o+2]) - Int(pc[2])) < 14 { continue }
        let fy = Double(S - 1 - y)
        cx += Double(x); cy += fy; n += 1
        minX = min(minX, Double(x)); maxX = max(maxX, Double(x))
        minY = min(minY, fy); maxY = max(maxY, fy)
    } }
    let k = Double(canvas) / Double(S)
    return (cx / n * k, cy / n * k, minX * k, maxX * k, minY * k, maxY * k)
}

for pal in [Palette.indigoPlate, .tealZalo, .monoDots] {
    let (icx, icy, mnX, mxX, mnY, mxY) = balance(pal)
    let name = ["A indigo plate", "B teal zalo", "C mono dots"][pal.rawValue]
    print(String(format: "%-16s lệch dx %+.1f dy %+.1f | lề T%.0f P%.0f D%.0f Tr%.0f",
                 (name as NSString).utf8String!, icx - 512, icy - 512,
                 mnX - 40, 984 - mxX, mnY - 40, 984 - mxY))
}

// ── Sheet ──
let big = 190, small = 48
let cellW = big + 22 + small + 34, cellH = big + 46
let sheetW = 26 * 2 + cellW * 3, sheetH = 26 * 2 + cellH + 40 + 150
let sctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sctx.setFillColor(rgb(242, 242, 245)); sctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: sctx, flipped: false)

let labels = ["A  plate indigo · 4 màu kênh", "B  plate xanh · zalo teal", "C  chấm cùng màu plate"]
for (i, pal) in [Palette.indigoPlate, .tealZalo, .monoDots].enumerated() {
    let x = 26 + i * cellW, y = sheetH - 26 - 40 - cellH + 46
    if let im = render(big * 2, { drawApp($0, pal) }) { sctx.draw(im, in: CGRect(x: x, y: y, width: big, height: big)) }
    if let im = render(small * 2, { drawApp($0, pal) }) { sctx.draw(im, in: CGRect(x: x + big + 22, y: y + big - small, width: small, height: small)) }
    (labels[i] as NSString).draw(at: NSPoint(x: x, y: y - 24),
        withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black])
    ("48px" as NSString).draw(at: NSPoint(x: x + big + 22, y: y + big - small - 17),
        withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray])
}

// Hàng tray: cỡ thật 20px trên hai nền menu bar, kèm zoom 96px
let ty = 34
("TRAY (template, đơn sắc) — 20px thật trên menu bar sáng / tối, và zoom 96px" as NSString)
    .draw(at: NSPoint(x: 26, y: ty + 104),
          withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.black])
if let tr = render(96, { drawTray($0) }) {
    // nền sáng
    sctx.setFillColor(rgb(233, 233, 233)); sctx.fill(CGRect(x: 26, y: ty + 40, width: 210, height: 52))
    if let t20 = render(20, { drawTray($0) }) { sctx.draw(t20, in: CGRect(x: 46, y: ty + 56, width: 20, height: 20)) }
    // nền tối: template thật sẽ được macOS đảo sang trắng — mô phỏng bằng cách vẽ trắng
    sctx.setFillColor(rgb(38, 38, 40)); sctx.fill(CGRect(x: 256, y: ty + 40, width: 210, height: 52))
    if let inv = render(20, { drawTray($0, white: true) }) {
        sctx.draw(inv, in: CGRect(x: 276, y: ty + 56, width: 20, height: 20)) }
    sctx.draw(tr, in: CGRect(x: 500, y: ty + 20, width: 96, height: 96))
}
NSGraphicsContext.restoreGraphicsState()

let url = URL(fileURLWithPath: "\(outDir)/icon-v2.png")
let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(d, sctx.makeImage()!, nil)
guard CGImageDestinationFinalize(d) else { exit(1) }
print("→ \(outDir)/icon-v2.png")
