// Favicon, Apple touch icon and the link-share image for bepresents.org.
// Usage: swift render-icons.swift <out-dir>
import AppKit
import CoreText
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
for f in ["InstrumentSerif-Regular.ttf", "InstrumentSerif-Italic.ttf"] {
    CTFontManagerRegisterFontsForURL(root.appending(path: "Shared/Fonts/\(f)") as CFURL, .process, nil)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ v: Int, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, alpha: a)
}
let media = [0xE2642E, 0xD257B4, 0x1A86A6, 0xBCD3DC, 0xE5D24A]

func canvas(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func save(_ ctx: CGContext, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appending(path: name))
    print("wrote \(name)")
}
func bg(_ ctx: CGContext, _ w: Int, _ h: Int) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(0x0B1B21), rgb(0x0A1215)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: .zero, options: [])
}
func glow(_ ctx: CGContext, center c: CGPoint, spread: Double, radius: Double, alpha: Double) {
    for (k, col) in media.enumerated() {
        let a = Double.pi / 2 - Double(k) * 2 * .pi / 5
        let p = CGPoint(x: c.x + cos(a) * spread, y: c.y + sin(a) * spread)
        let g = CGGradient(colorsSpace: space, colors: [rgb(col, alpha), rgb(col, alpha * 0.7), rgb(col, 0)] as CFArray, locations: [0, 0.3, 1])!
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
    }
}
/// The five-dot mark (y-up coordinates).
func mark(_ ctx: CGContext, center c: CGPoint, size: Double, color: Int = 0xFFFFFF) {
    let spots: [(Double, Double)] = [(0.5, 0.17), (0.83, 0.41), (0.7, 0.79), (0.3, 0.79), (0.17, 0.41)]
    ctx.setFillColor(rgb(color))
    for (sx, sy) in spots {
        let d = size * 0.27
        let x = c.x - size / 2 + sx * size, y = c.y + size / 2 - sy * size
        ctx.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
    }
}
func text(_ ctx: CGContext, _ s: String, font: String, size: Double, color: Int, centerX: Double, baselineY: Double) {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(color)]))
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: centerX - w / 2, y: baselineY)
    CTLineDraw(line, ctx)
}

// Icons: rounded dark tile, soft color glow, white mark.
for (name, n) in [("favicon-32.png", 32), ("favicon-192.png", 192), ("apple-touch-icon.png", 180), ("favicon-512.png", 512)] {
    let ctx = canvas(n, n)
    let d = Double(n)
    if name != "apple-touch-icon.png" {  // iOS rounds the touch icon itself
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: d, height: d), cornerWidth: d * 0.24, cornerHeight: d * 0.24, transform: nil))
        ctx.clip()
    }
    bg(ctx, n, n)
    if n >= 64 { glow(ctx, center: CGPoint(x: d / 2, y: d / 2), spread: d * 0.12, radius: d * 0.42, alpha: 0.75) }
    mark(ctx, center: CGPoint(x: d / 2, y: d / 2), size: d * (n >= 64 ? 0.42 : 0.7))
    save(ctx, name)
}

// Share image, 1200×630.
do {
    let W = 1200, H = 630
    let ctx = canvas(W, H)
    bg(ctx, W, H)
    glow(ctx, center: CGPoint(x: 600, y: 400), spread: 46, radius: 210, alpha: 0.8)
    mark(ctx, center: CGPoint(x: 600, y: 400), size: 74)
    text(ctx, "Presents", font: "InstrumentSerif-Regular", size: 96, color: 0xF3F5F2, centerX: 600, baselineY: 172)
    text(ctx, "capture a moment, together", font: "InstrumentSerif-Italic", size: 40, color: 0x8B9C9F, centerX: 600, baselineY: 108)
    // Film grain.
    let n = 256
    var px = [UInt8](repeating: 0, count: n * n)
    for k in 0..<px.count { let g = (Double.random(in: 0..<1) + Double.random(in: 0..<1) + Double.random(in: 0..<1) - 1.5) * 2; px[k] = UInt8(max(0, min(255, 128 + g * 22))) }
    let grain = px.withUnsafeMutableBytes { buf in
        CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!.makeImage()!
    }
    ctx.setBlendMode(.softLight); ctx.setAlpha(0.85)
    for x in stride(from: 0, to: W, by: n) { for y in stride(from: 0, to: H, by: n) { ctx.draw(grain, in: CGRect(x: x, y: y, width: n, height: n)) } }
    save(ctx, "og-image.png")
}
