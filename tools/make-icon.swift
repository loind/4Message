// Sinh iconset cho app. Vẽ vector bằng CoreGraphics rồi render riêng ở từng size
// (nét hơn là downscale từ 1024).
//
//   swift tools/make-icon.swift <thư-mục-iconset>
//
// Thiết kế gốc — KHÔNG dùng logo Messenger của Meta (trademark) và KHÔNG dùng
// SF Symbols (license cấm dùng symbol làm app icon / logo).

import AppKit
import CoreGraphics
import Foundation

/// Toàn bộ hình vẽ trong hệ toạ độ 1024×1024 rồi scale xuống size thật.
let canvas: CGFloat = 1024

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Corner tròn thường, không phải squircle liên tục của Apple — bù bằng bán kính
/// lớn hơn một chút cho gần giống.
func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(in ctx: CGContext) {

    // ── Nền: squircle màu bệt (flat, không gradient) ──
    let inset: CGFloat = 84
    let plate = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)

    ctx.saveGState()
    ctx.addPath(roundedRect(plate, 208))
    ctx.clip()

    ctx.setFillColor(rgb(74, 132, 255)); ctx.fill(plate)

    // Highlight nhẹ góc trên cho đỡ phẳng.
    ctx.restoreGState()

    // ── Bong bóng chat ──
    let bw: CGFloat = 470, bh: CGFloat = 404
    let bx = (canvas - bw) / 2
    // nudge 35: điểm giữa hai nghiệm "bbox cân" (58) và "centroid cân" (12). Hai thước đo
    // xung đột với hình có đuôi mảnh nên không thể cùng bằng 0 — xem
    // plans/2026-08-06-icon-4-dots/design.md và tools/icon-balance.swift.
    let by = (canvas - bh) / 2 + 35
    let bubble = CGRect(x: bx, y: by, width: bw, height: bh)

    let body = CGMutablePath()
    body.addPath(roundedRect(bubble, 128))

    // Đuôi bong bóng chĩa xuống trái. Ngắn và dày — kéo dài + mảnh thì ra hình
    // swoosh chứ không đọc ra là đuôi.
    // Bezier gốc, scale từ bubble 566×396 sang 470×404 — giữ đúng dáng đuôi nhọn cũ.
    let sx = bw / 566, sy = bh / 396
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: bx + x * sx, y: by + y * sy) }
    let tail = CGMutablePath()
    tail.move(to: P(148, 64))
    tail.addCurve(to: P(84, -112), control1: P(136, -24), control2: P(108, -74))
    tail.addCurve(to: P(338, 44), control1: P(206, -52), control2: P(274, 34))
    tail.closeSubpath()
    body.addPath(tail)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(20, 30, 90, 0.28))
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.addPath(body)
    ctx.fillPath()
    ctx.restoreGState()

    // ── Bốn chấm 2×2 = 4 kênh ──
    //
    // 2×2 chứ KHÔNG phải hàng 4: đo ở 48px thì hàng 4 nhoè thành một vạch, vì thêm chấm
    // thứ tư vào bề rộng cố định buộc bán kính co lại.
    //
    // Zalo dùng teal #12b3a8 thay màu thương hiệu #0068ff: plate và messenger đều là
    // #4a84ff, thêm zalo xanh nữa thì ở 48px logo đọc ra 3 màu chứ không phải 4.
    let dotR: CGFloat = 46
    let gap: CGFloat = 132
    let tints = [rgb(74, 132, 255), rgb(232, 65, 144), rgb(87, 87, 95), rgb(18, 179, 168)]
    for row in 0..<2 { for col in 0..<2 {
        let cx = bubble.midX + (CGFloat(col) - 0.5) * gap
        let cy = bubble.midY + (0.5 - CGFloat(row)) * gap
        ctx.setFillColor(tints[row * 2 + col])
        ctx.addEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        ctx.fillPath()
    } }
}

func render(size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.interpolationQuality = .high
    let scale = CGFloat(size) / canvas
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(in: ctx)
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw NSError(domain: "icon", code: 1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

// (tên file trong iconset, cạnh pixel)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, px) in variants {
    guard let image = render(size: px) else {
        FileHandle.standardError.write(Data("không render được \(name)\n".utf8))
        exit(1)
    }
    try writePNG(image, to: "\(outDir)/\(name).png")
}

// Bản xem trước để kiểm tra bằng mắt.
if let big = render(size: 1024) {
    try writePNG(big, to: "\(outDir)/../icon-preview.png")
}

print("đã sinh \(variants.count) PNG trong \(outDir)")
