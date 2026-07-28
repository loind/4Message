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
    let space = CGColorSpaceCreateDeviceRGB()

    // ── Nền: squircle với gradient chéo ──
    let inset: CGFloat = 84
    let plate = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)

    ctx.saveGState()
    ctx.addPath(roundedRect(plate, 208))
    ctx.clip()

    let bg = CGGradient(colorsSpace: space,
                        colors: [rgb(72, 132, 255), rgb(139, 74, 246)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: inset, y: canvas - inset),
                           end: CGPoint(x: canvas - inset, y: inset),
                           options: [])

    // Highlight nhẹ góc trên cho đỡ phẳng.
    let sheen = CGGradient(colorsSpace: space,
                           colors: [rgb(255, 255, 255, 0.22), rgb(255, 255, 255, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen,
                           startCenter: CGPoint(x: 300, y: 880), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 880), endRadius: 620,
                           options: [])
    ctx.restoreGState()

    // ── Bong bóng chat ──
    let bw: CGFloat = 566, bh: CGFloat = 396
    let bx = (canvas - bw) / 2
    let by = (canvas - bh) / 2 + 44
    let bubble = CGRect(x: bx, y: by, width: bw, height: bh)

    let body = CGMutablePath()
    body.addPath(roundedRect(bubble, 132))

    // Đuôi bong bóng chĩa xuống trái. Ngắn và dày — kéo dài + mảnh thì ra hình
    // swoosh chứ không đọc ra là đuôi.
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: bx + 148, y: by + 64))
    tail.addCurve(to: CGPoint(x: bx + 84, y: by - 112),
                  control1: CGPoint(x: bx + 136, y: by - 24),
                  control2: CGPoint(x: bx + 108, y: by - 74))
    tail.addCurve(to: CGPoint(x: bx + 338, y: by + 44),
                  control1: CGPoint(x: bx + 206, y: by - 52),
                  control2: CGPoint(x: bx + 274, y: by + 34))
    tail.closeSubpath()
    body.addPath(tail)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(20, 30, 90, 0.28))
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.addPath(body)
    ctx.fillPath()
    ctx.restoreGState()

    // ── Ba dấu chấm "đang nhập" ──
    let dotR: CGFloat = 38
    let gap: CGFloat = 134
    let cy = by + bh / 2 + 12
    for (i, tint) in [rgb(72, 132, 255), rgb(106, 103, 251), rgb(139, 74, 246)].enumerated() {
        let cx = canvas / 2 + CGFloat(i - 1) * gap
        ctx.setFillColor(tint)
        ctx.addEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        ctx.fillPath()
    }
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
