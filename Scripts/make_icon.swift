#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO

// Renders the AppSigner icon at a given pixel size: a white signature stroke on a
// blue gradient rounded tile, macOS-style (transparent corners, soft shadow).
func render(_ S: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let inset = S * 0.09
    let tile = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let TS = tile.width
    let radius = TS * 0.2237
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow behind the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.13, green: 0.33, blue: 0.85, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Blue gradient fill (clipped to the tile).
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.32, green: 0.60, blue: 1.00, alpha: 1),
        CGColor(red: 0.10, green: 0.29, blue: 0.83, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.minY), options: [])

    // Soft top highlight.
    ctx.saveGState()
    let gloss = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.midY + TS * 0.05), options: [])
    ctx.restoreGState()

    // White signature stroke.
    func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + fx * TS, y: tile.minY + fy * TS)
    }
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setShadow(offset: CGSize(width: 0, height: -TS * 0.01), blur: TS * 0.02,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))

    ctx.setLineWidth(TS * 0.062)
    let scribble = CGMutablePath()
    scribble.move(to: P(0.22, 0.45))
    scribble.addCurve(to: P(0.42, 0.66), control1: P(0.28, 0.54), control2: P(0.35, 0.66))
    scribble.addCurve(to: P(0.50, 0.40), control1: P(0.48, 0.66), control2: P(0.50, 0.52))
    scribble.addCurve(to: P(0.57, 0.64), control1: P(0.50, 0.30), control2: P(0.54, 0.64))
    scribble.addCurve(to: P(0.80, 0.52), control1: P(0.64, 0.64), control2: P(0.72, 0.55))
    ctx.addPath(scribble); ctx.strokePath()

    // Underline flourish.
    ctx.setLineWidth(TS * 0.05)
    let underline = CGMutablePath()
    underline.move(to: P(0.24, 0.31))
    underline.addCurve(to: P(0.78, 0.30), control1: P(0.45, 0.25), control2: P(0.62, 0.35))
    ctx.addPath(underline); ctx.strokePath()

    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("AppSigner.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    writePNG(render(px), to: iconset.appendingPathComponent("\(name).png"))
}
// Standalone preview.
writePNG(render(1024), to: root.appendingPathComponent("AppSigner-icon-preview.png"))
print("iconset + preview written")
