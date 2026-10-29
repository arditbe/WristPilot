// Draws the WristPilot logo and writes the app icons.
// Usage: swift Scripts/make-icons.swift   (run from the repository root)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let navyTop = CGColor(red: 0.17, green: 0.25, blue: 0.62, alpha: 1)
let navyBottom = CGColor(red: 0.05, green: 0.08, blue: 0.25, alpha: 1)
let gold = CGColor(red: 0.97, green: 0.77, blue: 0.33, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

enum Style {
    case mac      // rounded square with margin and shadow, transparent corners
    case watch    // full bleed and opaque; watchOS masks it to a circle
}

func drawBackground(_ ctx: CGContext, in rect: CGRect, clip: CGPath?) {
    ctx.saveGState()
    if let clip {
        ctx.addPath(clip)
        ctx.clip()
    }
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [navyTop, navyBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()
}

func drawWheel(_ ctx: CGContext, center c: CGPoint, unit u: CGFloat) {
    ctx.saveGState()
    ctx.setStrokeColor(gold)
    ctx.setFillColor(gold)
    ctx.setLineCap(.round)

    // Spokes with handles.
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 8
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        func point(_ r: CGFloat) -> CGPoint { CGPoint(x: c.x + direction.x * r * u, y: c.y + direction.y * r * u) }
        ctx.setLineWidth(0.035 * u)
        ctx.move(to: point(0.06))
        ctx.addLine(to: point(0.33))
        ctx.strokePath()
        ctx.setLineWidth(0.062 * u)
        ctx.move(to: point(0.335))
        ctx.addLine(to: point(0.395))
        ctx.strokePath()
    }

    // Rim.
    ctx.setLineWidth(0.05 * u)
    ctx.addEllipse(in: CGRect(x: c.x - 0.265 * u, y: c.y - 0.265 * u, width: 0.53 * u, height: 0.53 * u))
    ctx.strokePath()

    // Hub.
    ctx.addEllipse(in: CGRect(x: c.x - 0.085 * u, y: c.y - 0.085 * u, width: 0.17 * u, height: 0.17 * u))
    ctx.fillPath()
    ctx.restoreGState()
}

func drawPointer(_ ctx: CGContext, tip: CGPoint, height h: CGFloat) {
    // Classic arrow pointer, tip at the top-left, in y-down units of its height.
    let shape: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.80), (0.20, 0.62), (0.33, 0.93), (0.46, 0.87),
                                       (0.33, 0.57), (0.58, 0.57)]
    let path = CGMutablePath()
    for (index, (x, y)) in shape.enumerated() {
        let p = CGPoint(x: tip.x + x * h, y: tip.y - y * h)
        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -0.02 * h), blur: 0.08 * h,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.addPath(path)
    ctx.setFillColor(white)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(navyBottom)
    ctx.setLineWidth(0.045 * h)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

func render(size: Int, style: Style) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let body: CGRect
    switch style {
    case .mac:
        // macOS icon grid: 824/1024 body with rounded corners.
        body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225,
                           transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(navyBottom)
        ctx.fillPath()
        ctx.restoreGState()
        drawBackground(ctx, in: body, clip: shape)
    case .watch:
        body = CGRect(x: 0, y: 0, width: s, height: s)
        drawBackground(ctx, in: body, clip: nil)
    }

    let unit = style == .watch ? body.width * 0.92 : body.width
    let center = CGPoint(x: body.midX, y: body.midY)
    drawWheel(ctx, center: center, unit: unit)
    drawPointer(ctx, tip: CGPoint(x: center.x - 0.015 * unit, y: center.y + 0.02 * unit), height: 0.3 * unit)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func writeJSON(_ object: Any, to path: String) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
}

// Mac app icon.
let macSet = "Mac/Assets.xcassets/AppIcon.appiconset"
var macImages: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(render(size: pixels, style: .mac), to: "\(macSet)/\(name)")
        macImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
writeJSON(["images": macImages, "info": ["author": "xcode", "version": 1]], to: "\(macSet)/Contents.json")
writeJSON(["info": ["author": "xcode", "version": 1]], to: "Mac/Assets.xcassets/Contents.json")

// Watch app icon (single size).
let watchSet = "Watch/Assets.xcassets/AppIcon.appiconset"
write(render(size: 1024, style: .watch), to: "\(watchSet)/AppIcon.png")
writeJSON(["images": [["filename": "AppIcon.png", "idiom": "universal", "platform": "watchos", "size": "1024x1024"]],
           "info": ["author": "xcode", "version": 1]], to: "\(watchSet)/Contents.json")
writeJSON(["info": ["author": "xcode", "version": 1]], to: "Watch/Assets.xcassets/Contents.json")

// Logo for the README.
write(render(size: 512, style: .mac), to: "docs/logo.png")
print("Icons written.")
