#!/usr/bin/env swift
//
// PhotoX app icon generator.
// Renders a dark glossy-squircle background with a centered photo frame
// and a big gold star, then writes PNGs at all macOS app-icon sizes into
// two asset catalogs:
//   PhotoX/Assets.xcassets/AppIcon.appiconset/        ← Release
//   PhotoX/Assets.xcassets/AppIcon-Debug.appiconset/  ← Debug (amber DEV pill)
//
// Run from repo root: `swift scripts/generate_icon.swift` (or `just icon`).
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let releaseDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("PhotoX/Assets.xcassets/AppIcon.appiconset")
let debugDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("PhotoX/Assets.xcassets/AppIcon-Debug.appiconset")
let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]

@discardableResult
func renderIcon(size sizePx: Int) -> CGImage? {
    let s = CGFloat(sizePx)
    let cs = CGColorSpaceCreateDeviceRGB()
    let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: sizePx, height: sizePx,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: bitmap) else {
        return nil
    }

    // ------ 1. Squircle background with vertical gradient ------
    let cornerR = s * 0.225  // close to macOS continuous corner ratio
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: bgRect,
                        cornerWidth: cornerR, cornerHeight: cornerR,
                        transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let bgColors = [
        CGColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1.0),  // top
        CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0),  // bottom
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient,
                            start: CGPoint(x: 0, y: s),
                            end: CGPoint(x: 0, y: 0),
                            options: [])

    // ------ 2. Top inner highlight (suggests glossy light from above) ------
    let hlColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.14),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    let hlGradient = CGGradient(colorsSpace: cs, colors: hlColors, locations: [0, 1])!
    ctx.drawLinearGradient(hlGradient,
                            start: CGPoint(x: 0, y: s),
                            end: CGPoint(x: 0, y: s * 0.78),
                            options: [])
    ctx.restoreGState()

    // ------ 3. Photo frame (rounded rect, slightly lifted with shadow) ------
    let photoW = s * 0.62
    let photoH = photoW * (2.0 / 3.0)  // 3:2 photo aspect
    let photoX = (s - photoW) / 2
    let photoY = (s - photoH) / 2
    let photoCorner = s * 0.022
    let photoRect = CGRect(x: photoX, y: photoY, width: photoW, height: photoH)
    let photoPath = CGPath(roundedRect: photoRect,
                            cornerWidth: photoCorner, cornerHeight: photoCorner,
                            transform: nil)

    // Drop shadow (separates the photo from the dark squircle)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018),
                   blur: s * 0.06,
                   color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.75))
    ctx.addPath(photoPath)
    ctx.setFillColor(CGColor(red: 0.40, green: 0.40, blue: 0.44, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Photo inner gradient — much brighter top than before, so the photo
    // clearly stands away from the dark squircle.
    ctx.saveGState()
    ctx.addPath(photoPath)
    ctx.clip()
    let photoColors = [
        CGColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1.0),  // top — sky-ish
        CGColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1.0),  // bottom — ground-ish
    ] as CFArray
    let photoGradient = CGGradient(colorsSpace: cs, colors: photoColors, locations: [0, 1])!
    ctx.drawLinearGradient(photoGradient,
                            start: CGPoint(x: 0, y: photoY + photoH),
                            end: CGPoint(x: 0, y: photoY),
                            options: [])

    // Soft horizon line ~42 % from bottom — suggests "a photo of something"
    // without committing to literal content.
    let horizonY = photoY + photoH * 0.42
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.setLineWidth(s * 0.004)
    ctx.move(to: CGPoint(x: photoX + photoW * 0.05, y: horizonY))
    ctx.addLine(to: CGPoint(x: photoX + photoW * 0.95, y: horizonY))
    ctx.strokePath()
    ctx.restoreGState()

    // Thin inner highlight border — gives the photo a slight glass / lit feel.
    ctx.saveGState()
    ctx.addPath(photoPath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(s * 0.005)
    ctx.strokePath()
    ctx.restoreGState()

    // ------ 4. Gold star centered on the photo ------
    let starRadius = s * 0.21
    let starCenter = CGPoint(x: s / 2, y: s / 2)
    drawStar(in: ctx, center: starCenter, outerRadius: starRadius, colorSpace: cs, canvasSize: s)

    return ctx.makeImage()
}

/// 5-pointed star with vertical gold gradient + subtle outline + soft shadow.
func drawStar(in ctx: CGContext,
              center: CGPoint,
              outerRadius rOut: CGFloat,
              colorSpace cs: CGColorSpace,
              canvasSize s: CGFloat)
{
    let points = 5
    let rIn = rOut * 0.40
    let path = CGMutablePath()
    for i in 0..<(points * 2) {
        let isOuter = i % 2 == 0
        let radius = isOuter ? rOut : rIn
        // CG coords are y-up — for the first vertex to appear at the TOP of
        // the rendered image we want HIGH y in CG, so start at +π/2.
        let angle = CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
        let x = center.x + radius * cos(angle)
        let y = center.y + radius * sin(angle)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()

    // Soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008),
                   blur: s * 0.025,
                   color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.28, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Gold gradient fill (over the flat fill)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let goldColors = [
        CGColor(red: 1.00, green: 0.92, blue: 0.55, alpha: 1.0),  // top: pale gold
        CGColor(red: 0.85, green: 0.58, blue: 0.13, alpha: 1.0),  // bottom: deep amber
    ] as CFArray
    let goldGradient = CGGradient(colorsSpace: cs, colors: goldColors, locations: [0, 1])!
    ctx.drawLinearGradient(goldGradient,
                            start: CGPoint(x: 0, y: center.y + rOut),
                            end: CGPoint(x: 0, y: center.y - rOut),
                            options: [])
    ctx.restoreGState()

    // Subtle outline
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 0.38, green: 0.22, blue: 0.03, alpha: 0.75))
    ctx.setLineWidth(rOut * 0.04)
    ctx.strokePath()
    ctx.restoreGState()

    // Soft top highlight on star (small white-ish gleam)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gleamColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    let gleamGradient = CGGradient(colorsSpace: cs, colors: gleamColors, locations: [0, 1])!
    ctx.drawLinearGradient(gleamGradient,
                            start: CGPoint(x: 0, y: center.y + rOut),
                            end: CGPoint(x: 0, y: center.y + rOut * 0.1),
                            options: [])
    ctx.restoreGState()
}

/// Draws an amber "DEV" pill at the bottom-center of `ctx`, sized to
/// roughly 22 % of the icon height. Text is skipped below 48 px (would
/// be unreadable smudge); the pill colour alone is enough to flag the
/// debug build at small sizes.
func drawDevPill(in ctx: CGContext, sizePx: Int, colorSpace cs: CGColorSpace) {
    let s = CGFloat(sizePx)
    let pillW = s * 0.50
    let pillH = s * 0.22
    let pillX = (s - pillW) / 2
    let pillY = s * 0.06             // bottom-center inset
    let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
    let pillPath = CGPath(roundedRect: pillRect,
                          cornerWidth: pillH / 2,
                          cornerHeight: pillH / 2,
                          transform: nil)

    // Soft drop shadow so the pill lifts off the photo behind it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                   blur: s * 0.04,
                   color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
    ctx.addPath(pillPath)
    ctx.setFillColor(CGColor(red: 1.00, green: 0.78, blue: 0.10, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Amber → darker amber vertical gradient (subtle, matches the gold star).
    ctx.saveGState()
    ctx.addPath(pillPath)
    ctx.clip()
    let pillColors = [
        CGColor(red: 1.00, green: 0.86, blue: 0.30, alpha: 1.0),
        CGColor(red: 0.92, green: 0.66, blue: 0.05, alpha: 1.0),
    ] as CFArray
    let pillGradient = CGGradient(colorsSpace: cs, colors: pillColors, locations: [0, 1])!
    ctx.drawLinearGradient(pillGradient,
                            start: CGPoint(x: 0, y: pillY + pillH),
                            end: CGPoint(x: 0, y: pillY),
                            options: [])
    ctx.restoreGState()

    // Thin dark outline so the pill reads on light photo backgrounds too.
    ctx.saveGState()
    ctx.addPath(pillPath)
    ctx.setStrokeColor(CGColor(red: 0.20, green: 0.10, blue: 0.0, alpha: 0.85))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.strokePath()
    ctx.restoreGState()

    // Text only at sizes where it'd actually be legible. Below ~48 px the
    // text would render as a 6–8 px smudge — the amber colour alone is
    // enough of a "this is the dev build" tell at small sizes.
    guard sizePx >= 48 else { return }

    let text = "DEV"
    let fontSize = pillH * 0.62
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    // CoreText attribute keys — using these directly (rather than the
    // AppKit-extended `NSAttributedString.Key.font` constants) keeps the
    // script runnable as a pure `swift` interpreter invocation, no
    // AppKit import required.
    let attrs: CFDictionary = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(red: 0.20, green: 0.10, blue: 0.0, alpha: 1.0),
    ] as CFDictionary
    let attributed = CFAttributedStringCreate(nil, text as CFString, attrs)!
    let line = CTLineCreateWithAttributedString(attributed)
    let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let textX = pillX + (pillW - textBounds.width) / 2 - textBounds.origin.x
    let textY = pillY + (pillH - textBounds.height) / 2 - textBounds.origin.y

    ctx.saveGState()
    ctx.textPosition = CGPoint(x: textX, y: textY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// Overlay the DEV pill onto a copy of `base` and return the composited
/// CGImage. Keeps `base` untouched so the same base render serves both
/// iconsets without re-drawing the whole icon.
func overlayDevPill(on base: CGImage, sizePx: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: sizePx, height: sizePx,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: bitmap) else {
        return nil
    }
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: sizePx, height: sizePx))
    drawDevPill(in: ctx, sizePx: sizePx, colorSpace: cs)
    return ctx.makeImage()
}

/// The Contents.json shape is identical for both iconsets — same set of
/// scale / size declarations pointing at filenames the generator just
/// wrote. Re-emitting it here keeps the iconset self-describing if a
/// devappends a new size in the future.
let contentsJSON = """
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16.png",   "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_32.png",   "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32.png",   "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_64.png",   "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128.png",  "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_256.png",  "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256.png",  "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_512.png",  "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512.png",  "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_1024.png", "scale" : "2x" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

func savePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                      UTType.png.identifier as CFString,
                                                      1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "icon", code: 2)
    }
}

// ----- main -----
for dir in [releaseDir, debugDir] {
    try? FileManager.default.createDirectory(at: dir,
                                              withIntermediateDirectories: true)
    try? contentsJSON.write(
        to: dir.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8
    )
}

for size in sizes {
    guard let base = renderIcon(size: size) else {
        FileHandle.standardError.write(Data("Failed to render \(size)px\n".utf8))
        continue
    }

    // Release: clean icon.
    let releaseURL = releaseDir.appendingPathComponent("icon_\(size).png")
    do {
        try savePNG(base, to: releaseURL)
        print("Wrote Release \(releaseURL.lastPathComponent) (\(size)px)")
    } catch {
        FileHandle.standardError.write(Data("Failed to save \(releaseURL.lastPathComponent): \(error)\n".utf8))
    }

    // Debug: same base + amber DEV pill.
    guard let dev = overlayDevPill(on: base, sizePx: size) else {
        FileHandle.standardError.write(Data("Failed to overlay DEV pill at \(size)px\n".utf8))
        continue
    }
    let debugURL = debugDir.appendingPathComponent("icon_\(size).png")
    do {
        try savePNG(dev, to: debugURL)
        print("Wrote Debug   \(debugURL.lastPathComponent) (\(size)px)")
    } catch {
        FileHandle.standardError.write(Data("Failed to save \(debugURL.lastPathComponent): \(error)\n".utf8))
    }
}
