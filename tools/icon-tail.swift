// So ba kiểu đuôi trên phương án B (plate xanh, zalo teal) — chốt riêng chuyện cái đuôi.
//
//   swift tools/icon-tail.swift <thư-mục-out>
//
// "Nhọn như cũ" có hai nghĩa: nhọn trên hình học v2, hay đúng đường bezier của icon đang
// ship. Dựng cả hai cạnh bản tròn để chỉ bằng mắt thay vì tôi đoán.
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
func hex(_ s: String) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return rgb(CGFloat((v >> 16) & 0xff), CGFloat((v >> 8) & 0xff), CGFloat(v & 0xff))
}
func roundedRect(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

let plate = CGRect(x: 40, y: 40, width: canvas - 80, height: canvas - 80)
let bubbleW: CGFloat = 470, bubbleH: CGFloat = 404, corner: CGFloat = 128
let dotR: CGFloat = 46, dotGap: CGFloat = 132
let brand = hex("#4a84ff")
// Phương án B đã chốt.
let dots = ["#4a84ff", "#e84190", "#57575f", "#12b3a8"].map { hex($0) }

enum Tail: Int { case sharp = 0, original = 1, rounded = 2 }
// Đuôi đổi chiều cao thì khối mực đổi, nên nudge phải đo lại cho từng kiểu.
func tailHeight(_ t: Tail) -> CGFloat { t == .original ? 114 : 78 }
var nudgeCache: [Int: CGFloat] = [:]
func nudge(_ t: Tail) -> CGFloat { nudgeCache[t.rawValue] ?? 0 }

func bubbleRect(_ t: Tail) -> CGRect {
    CGRect(x: (canvas - bubbleW) / 2, y: (canvas - bubbleH) / 2 + nudge(t),
           width: bubbleW, height: bubbleH)
}

func bubblePath(_ t: Tail) -> CGPath {
    let b = bubbleRect(t)
    let p = CGMutablePath()
    p.addPath(roundedRect(b, corner))
    let tp = CGMutablePath()
    switch t {
    case .sharp, .rounded:
        // Tam giác; bán kính đỉnh 0 = nhọn, 20 = tròn.
        let ax = b.minX + corner * 0.58
        tp.move(to: CGPoint(x: ax, y: b.minY + 6))
        tp.addArc(tangent1End: CGPoint(x: ax - 66, y: b.minY - tailHeight(t)),
                  tangent2End: CGPoint(x: ax + 104, y: b.minY + 6),
                  radius: t == .sharp ? 0.01 : 20)
        tp.addLine(to: CGPoint(x: ax + 104, y: b.minY + 6))
    case .original:
        // Đúng bezier của tools/make-icon.swift, scale từ bubble 566×396 sang 470×404.
        let sx = bubbleW / 566, sy = bubbleH / 396
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: b.minX + x * sx, y: b.minY + y * sy)
        }
        tp.move(to: P(148, 64))
        tp.addCurve(to: P(84, -112), control1: P(136, -24), control2: P(108, -74))
        tp.addCurve(to: P(338, 44), control1: P(206, -52), control2: P(274, 34))
    }
    tp.closeSubpath()
    p.addPath(tp)
    return p
}

func dotCenters(_ t: Tail) -> [CGPoint] {
    let b = bubbleRect(t)
    var pts: [CGPoint] = []
    for row in 0..<2 { for col in 0..<2 {
        pts.append(CGPoint(x: b.midX + (CGFloat(col) - 0.5) * dotGap,
                           y: b.midY + (0.5 - CGFloat(row)) * dotGap))
    } }
    return pts
}

func drawApp(_ ctx: CGContext, _ t: Tail, border: Bool = true) {
    ctx.saveGState()
    ctx.addPath(roundedRect(plate, 208)); ctx.clip()
    ctx.setFillColor(brand); ctx.fill(plate)
    ctx.restoreGState()
    if border {
        ctx.addPath(roundedRect(plate.insetBy(dx: 1.5, dy: 1.5), 207))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.26)); ctx.setLineWidth(3); ctx.strokePath()
    }
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.addPath(bubblePath(t)); ctx.fillPath()
    for (i, c) in dotCenters(t).enumerated() {
        ctx.setFillColor(dots[i])
        ctx.addEllipse(in: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2))
        ctx.fillPath()
    }
}

func drawTray(_ ctx: CGContext, _ t: Tail, white: Bool = false) {
    let bb = bubblePath(t).boundingBox
    let pad: CGFloat = 26
    let k = min((canvas - pad * 2) / bb.width, (canvas - pad * 2) / bb.height)
    ctx.saveGState()
    ctx.translateBy(x: (canvas - bb.width * k) / 2 - bb.minX * k,
                    y: (canvas - bb.height * k) / 2 - bb.minY * k)
    ctx.scaleBy(x: k, y: k)
    ctx.setFillColor(white ? rgb(255, 255, 255) : rgb(0, 0, 0))
    ctx.addPath(bubblePath(t)); ctx.fillPath()
    ctx.setBlendMode(.destinationOut)
    for c in dotCenters(t) {
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

func balance(_ t: Tail) -> (Double, Double, Double, Double) {
    let S = 512
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(S) / canvas, y: CGFloat(S) / canvas)
    drawApp(ctx, t, border: false)
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: S * S * 4)
    let pc = brand.components!.map { UInt8(($0 * 255).rounded()) }
    var cy = 0.0, n = 0.0, minY = 1e9, maxY = -1e9
    for y in 4..<(S - 4) { for x in 4..<(S - 4) {
        let o = (y * S + x) * 4
        if px[o+3] < 250 { continue }
        if abs(Int(px[o]) - Int(pc[0])) < 14 && abs(Int(px[o+1]) - Int(pc[1])) < 14
            && abs(Int(px[o+2]) - Int(pc[2])) < 14 { continue }
        let fy = Double(S - 1 - y)
        cy += fy; n += 1; minY = min(minY, fy); maxY = max(maxY, fy)
    } }
    let k = Double(canvas) / Double(S)
    return (cy / n * k - 512, minY * k - 40, 984 - maxY * k, 0)
}

// Giải nudge cho từng kiểu để cả ba CÙNG cân dọc — không thì so đuôi lẫn với so vị trí.
//
// Hai mục tiêu xung đột và không thể cùng bằng 0 với hình có đuôi mảnh:
//   nBbox     — bbox cân tuyệt đối, nhưng khối mực bị đẩy lên cao 3-4%
//   nCentroid — khối mực cân, nhưng silhouette nhìn chìm xuống
// Lấy ĐIỂM GIỮA: sai số lớn nhất của hai phía nhỏ nhất có thể.
for t in [Tail.sharp, .original, .rounded] {
    nudgeCache[t.rawValue] = 0
    let (dy0, below0, above0, _) = balance(t)
    let nBbox = (above0 - below0) / 2
    let nCentroid = -dy0
    nudgeCache[t.rawValue] = CGFloat((nBbox + nCentroid) / 2)
}

let names = ["1  nhọn (hình học v2)", "2  bezier gốc đang ship", "3  tròn (v2 hiện tại)"]
for t in [Tail.sharp, .original, .rounded] {
    let (dy, below, above, _) = balance(t)
    let label = names[t.rawValue].padding(toLength: 26, withPad: " ", startingAt: 0)
    print(label + String(format: "centroid dy %+6.1f | lề dưới %.0f  trên %.0f  (lệch %.0f)  nudge %.0f",
                         dy, below, above, below - above, nudge(t)))
}

// ── Sheet: 3 kiểu × (190px, 48px, tray 20px sáng/tối) ──
let big = 190, small = 48
let cellW = big + 20 + small + 40, cellH = big + 96
let sheetW = 26 * 2 + cellW * 3, sheetH = 26 * 2 + cellH + 30
let s = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
s.setFillColor(rgb(242, 242, 245)); s.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: s, flipped: false)

for t in [Tail.sharp, .original, .rounded] {
    let i = t.rawValue
    let x = 26 + i * cellW, y = sheetH - 26 - cellH + 96
    if let im = render(big * 2, { drawApp($0, t) }) { s.draw(im, in: CGRect(x: x, y: y, width: big, height: big)) }
    if let im = render(small * 2, { drawApp($0, t) }) { s.draw(im, in: CGRect(x: x + big + 20, y: y + big - small, width: small, height: small)) }
    (names[i] as NSString).draw(at: NSPoint(x: x, y: y - 24),
        withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black])
    // tray cỡ thật, hai nền
    s.setFillColor(rgb(233, 233, 233)); s.fill(CGRect(x: x, y: y - 78, width: 96, height: 44))
    if let im = render(20, { drawTray($0, t) }) { s.draw(im, in: CGRect(x: x + 38, y: y - 68, width: 20, height: 20)) }
    s.setFillColor(rgb(38, 38, 40)); s.fill(CGRect(x: x + 104, y: y - 78, width: 96, height: 44))
    if let im = render(20, { drawTray($0, t, white: true) }) { s.draw(im, in: CGRect(x: x + 142, y: y - 68, width: 20, height: 20)) }
    ("tray 20px" as NSString).draw(at: NSPoint(x: x, y: y - 96),
        withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray])
}
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: "\(outDir)/icon-tails.png")
let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(d, s.makeImage()!, nil)
guard CGImageDestinationFinalize(d) else { exit(1) }
print("→ \(outDir)/icon-tails.png")
