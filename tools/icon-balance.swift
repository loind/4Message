// Đo cân bằng quang học của icon rồi vẽ đường gióng để kiểm bằng mắt.
//
//   swift tools/icon-balance.swift <thư-mục-out>
//
// Vì sao cần đo: bubble căn giữa theo TOÁN không có nghĩa là căn giữa theo MẮT. Đuôi chĩa
// xuống trái kéo khối mực lệch xuống-trái, và lệch 1-2% thì mắt thấy "sai" mà không chỉ ra
// được sai ở đâu. Đo centroid pixel là cách duy nhất nói được con số.
//
// In ra: centroid mực so với tâm plate, lề bubble 4 phía, và tâm cụm chấm so với thân bubble.

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

// ── Knob hình học. Sửa ở đây rồi chạy lại để xem số đổi thế nào. ──
struct Geo {
    var bubbleW: CGFloat = 470      // thu từ 566: cụm chấm 2×2 là hình vuông, bubble quá
    var bubbleH: CGFloat = 404      // rộng thì hở hai bên
    var bubbleDX: CGFloat = 0       // bù quang học ngang (đuôi lệch trái)
    var bubbleDY: CGFloat = 0       // bù quang học dọc (đuôi kéo xuống)
    var corner: CGFloat = 128
    var dotR: CGFloat = 46
    var dotGap: CGFloat = 132
    var tailW: CGFloat = 150        // đuôi nhỏ hơn bản cũ (254) cho đọc ra là đuôi
    var tailH: CGFloat = 86         // thay vì swoosh
}
var g = Geo()
if let e = ProcessInfo.processInfo.environment["ICON_DX"], let v = Double(e) { g.bubbleDX = CGFloat(v) }
if let e = ProcessInfo.processInfo.environment["ICON_DY"], let v = Double(e) { g.bubbleDY = CGFloat(v) }

let plate = CGRect(x: 40, y: 40, width: canvas - 80, height: canvas - 80)
let serviceTints = ["#4a84ff", "#e84190", "#57575f", "#0068ff"].map { hex($0) }
let brand = hex("#4a84ff")

func bubbleRect() -> CGRect {
    CGRect(x: (canvas - g.bubbleW) / 2 + g.bubbleDX,
           y: (canvas - g.bubbleH) / 2 + g.bubbleDY,
           width: g.bubbleW, height: g.bubbleH)
}

/// Thân + đuôi. Đuôi bám mép dưới-trái của thân, cong về phía trong.
func bubblePath() -> CGPath {
    let b = bubbleRect()
    let p = CGMutablePath()
    p.addPath(roundedRect(b, g.corner))
    let t = CGMutablePath()
    let ax = b.minX + g.corner * 0.72          // điểm neo trên, nằm trong bo góc
    t.move(to: CGPoint(x: ax, y: b.minY + 30))
    t.addCurve(to: CGPoint(x: ax - g.tailW * 0.34, y: b.minY - g.tailH),
               control1: CGPoint(x: ax - 8, y: b.minY - g.tailH * 0.34),
               control2: CGPoint(x: ax - g.tailW * 0.22, y: b.minY - g.tailH * 0.78))
    t.addCurve(to: CGPoint(x: ax + g.tailW * 0.62, y: b.minY + 22),
               control1: CGPoint(x: ax + g.tailW * 0.10, y: b.minY - g.tailH * 0.42),
               control2: CGPoint(x: ax + g.tailW * 0.48, y: b.minY - 6))
    t.closeSubpath()
    p.addPath(t)
    return p
}

func dotCenters() -> [CGPoint] {
    let b = bubbleRect()
    let cx = b.midX, cy = b.midY
    var pts: [CGPoint] = []
    for row in 0..<2 { for col in 0..<2 {
        pts.append(CGPoint(x: cx + (CGFloat(col) - 0.5) * g.dotGap,
                           y: cy + (0.5 - CGFloat(row)) * g.dotGap))
    } }
    return pts
}

func drawIcon(_ ctx: CGContext, border: Bool = true) {
    ctx.saveGState()
    ctx.addPath(roundedRect(plate, 208)); ctx.clip()
    ctx.setFillColor(brand); ctx.fill(plate)
    ctx.restoreGState()
    if border {
        ctx.addPath(roundedRect(plate.insetBy(dx: 1.5, dy: 1.5), 207))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.26)); ctx.setLineWidth(3); ctx.strokePath()
    }

    ctx.setFillColor(rgb(255, 255, 255))
    ctx.addPath(bubblePath()); ctx.fillPath()

    for (i, c) in dotCenters().enumerated() {
        ctx.setFillColor(serviceTints[i])
        ctx.addEllipse(in: CGRect(x: c.x - g.dotR, y: c.y - g.dotR,
                                  width: g.dotR * 2, height: g.dotR * 2))
        ctx.fillPath()
    }
}

func render(size: Int, _ body: (CGContext) -> Void) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    body(ctx)
    return ctx.makeImage()
}

// ── ĐO: centroid của "mực" = pixel KHÁC màu plate, trong vùng plate ──
struct Metrics { var cx = 0.0; var cy = 0.0; var minX = 1e9; var maxX = -1e9; var minY = 1e9; var maxY = -1e9; var n = 0 }

func measure(_ size: Int) -> Metrics {
    var m = Metrics()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let buf = ctx.data else { return m }
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(ctx, border: false)
    let px = buf.bindMemory(to: UInt8.self, capacity: size * size * 4)
    // Màu plate ở dạng 8-bit để so.
    let pc = brand.components!.map { UInt8(($0 * 255).rounded()) }
    let edge = max(3, size / 100)   // bỏ mép anti-alias của plate
    for y in edge..<(size - edge) { for x in edge..<(size - edge) {
        let o = (y * size + x) * 4
        let (r, gg, b, a) = (px[o], px[o+1], px[o+2], px[o+3])
        // Phải là alpha ĐẦY: plate clip theo bo góc nên pixel mép là brand blend sang
        // trong suốt, mà premultipliedLast nhân RGB xuống nên nó không còn khớp màu brand
        // và bị tính thành "mực" — đó là lý do bbox từng trùm cả plate (40..982).
        if a < 250 { continue }
        let isPlate = abs(Int(r) - Int(pc[0])) < 14 && abs(Int(gg) - Int(pc[1])) < 14 && abs(Int(b) - Int(pc[2])) < 14
        if isPlate { continue }                                   // nền, không phải mực
        m.cx += Double(x); m.cy += Double(size - 1 - y); m.n += 1  // đảo y về hệ CG
        m.minX = min(m.minX, Double(x)); m.maxX = max(m.maxX, Double(x))
        m.minY = min(m.minY, Double(size - 1 - y)); m.maxY = max(m.maxY, Double(size - 1 - y))
    } }
    if m.n > 0 { m.cx /= Double(m.n); m.cy /= Double(m.n) }
    return m
}

let S = 512
let m = measure(S)
let k = canvas / CGFloat(S)                     // đổi px đo về hệ 1024
let plateCx = Double(plate.midX), plateCy = Double(plate.midY)
let inkCx = m.cx * Double(k), inkCy = m.cy * Double(k)
let b = bubbleRect()

print("── CÂN BẰNG (hệ toạ độ 1024) ──")
print(String(format: "  tâm plate          : %.1f, %.1f", plateCx, plateCy))
print(String(format: "  centroid mực       : %.1f, %.1f", inkCx, inkCy))
print(String(format: "  LỆCH               : dx %+.1f  dy %+.1f   (%.2f%% / %.2f%% cạnh plate)",
             inkCx - plateCx, inkCy - plateCy,
             abs(inkCx - plateCx) / Double(plate.width) * 100,
             abs(inkCy - plateCy) / Double(plate.height) * 100))
print(String(format: "  bbox mực           : x %.0f..%.0f   y %.0f..%.0f",
             m.minX * Double(k), m.maxX * Double(k), m.minY * Double(k), m.maxY * Double(k)))
print(String(format: "  lề mực → plate     : trái %.0f  phải %.0f  dưới %.0f  trên %.0f",
             m.minX * Double(k) - Double(plate.minX), Double(plate.maxX) - m.maxX * Double(k),
             m.minY * Double(k) - Double(plate.minY), Double(plate.maxY) - m.maxY * Double(k)))
let dc = dotCenters()
let dotCx = dc.map { Double($0.x) }.reduce(0, +) / 4, dotCy = dc.map { Double($0.y) }.reduce(0, +) / 4
print(String(format: "  cụm chấm vs thân   : dx %+.1f  dy %+.1f", dotCx - Double(b.midX), dotCy - Double(b.midY)))
print(String(format: "  lề chấm trong thân : ngang %.0f  dọc %.0f",
             dc.map { Double($0.x) }.min()! - Double(g.dotR) - Double(b.minX),
             dc.map { Double($0.y) }.min()! - Double(g.dotR) - Double(b.minY)))

// ── Ảnh có đường gióng ──
if let img = render(size: 1024, { ctx in
    drawIcon(ctx)
    // tâm plate: xanh lá | centroid mực: đỏ
    ctx.setStrokeColor(rgb(0, 200, 90, 0.95)); ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: plate.midX, y: plate.minY)); ctx.addLine(to: CGPoint(x: plate.midX, y: plate.maxY))
    ctx.move(to: CGPoint(x: plate.minX, y: plate.midY)); ctx.addLine(to: CGPoint(x: plate.maxX, y: plate.midY))
    ctx.strokePath()
    ctx.setStrokeColor(rgb(255, 40, 40, 0.95)); ctx.setLineWidth(3)
    ctx.setLineDash(phase: 0, lengths: [14, 10])
    ctx.move(to: CGPoint(x: CGFloat(inkCx), y: plate.minY)); ctx.addLine(to: CGPoint(x: CGFloat(inkCx), y: plate.maxY))
    ctx.move(to: CGPoint(x: plate.minX, y: CGFloat(inkCy))); ctx.addLine(to: CGPoint(x: plate.maxX, y: CGFloat(inkCy)))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
}) {
    let url = URL(fileURLWithPath: "\(outDir)/icon-guides.png")
    let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); _ = CGImageDestinationFinalize(d)
    print("  → \(outDir)/icon-guides.png  (lá = tâm plate, đỏ nét đứt = centroid mực)")
}
// Dải cỡ thật để kiểm legibility
for px in [128, 64, 48, 32] {
    if let img = render(size: px, { drawIcon($0) }) {
        let url = URL(fileURLWithPath: "\(outDir)/icon-\(px).png")
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil); _ = CGImageDestinationFinalize(d)
    }
}
print("  → \(outDir)/icon-{128,64,48,32}.png")
