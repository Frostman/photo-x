#!/usr/bin/env swift
//
// PhotoX app icon generator.
// Renders a dark glossy-squircle background with a centered photo frame
// and a big gold star, then writes PNGs at all macOS app-icon sizes into
// PhotoX/Assets.xcassets/AppIcon.appiconset/.
//
// Run from repo root: `swift scripts/generate_icon.swift`
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("PhotoX/Assets.xcassets/AppIcon.appiconset")
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
try? FileManager.default.createDirectory(at: outputDir,
                                          withIntermediateDirectories: true)
for size in sizes {
    guard let img = renderIcon(size: size) else {
        FileHandle.standardError.write(Data("Failed to render \(size)px\n".utf8))
        continue
    }
    let url = outputDir.appendingPathComponent("icon_\(size).png")
    do {
        try savePNG(img, to: url)
        print("Wrote \(url.lastPathComponent) (\(size)px)")
    } catch {
        FileHandle.standardError.write(Data("Failed to save \(url.lastPathComponent): \(error)\n".utf8))
    }
}
