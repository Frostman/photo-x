import AppKit
import IndexingCore
import SwiftUI

/// Draws AF / focus regions over the canvas, transformed by the same viewport
/// the Metal renderer uses. Region rects are in IMAGE pixel coordinates
/// (origin top-left, y-down); we convert to canvas POINTS (origin top-left,
/// y-down) for SwiftUI rendering.
struct AFPointOverlay: View {
    let imagePixelSize: CGSize
    let viewport: CanvasViewport
    let regions: [AFRegion]

    var body: some View {
        GeometryReader { geom in
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let canvas = geom.size

            let fit = min(canvas.width / imagePixelSize.width,
                          canvas.height / imagePixelSize.height)
            let effScale = fit * viewport.scale  // image-px → canvas-points

            // viewport.offset is in device pixels with +y up.
            let offsetXPts = viewport.offset.x / scale
            let offsetYPts = viewport.offset.y / scale

            let imageWPts = imagePixelSize.width * effScale
            let imageHPts = imagePixelSize.height * effScale

            let centerXPts = canvas.width / 2 + offsetXPts
            let centerYPts = canvas.height / 2 - offsetYPts  // flip y

            let topLeftXPts = centerXPts - imageWPts / 2
            let topLeftYPts = centerYPts - imageHPts / 2

            // Draw focal-plane dots BEHIND boxes so the primary box reads on top.
            ForEach(regions.filter { $0.kind == .focalPlanePoint }) { region in
                focalPlaneDot(for: region,
                              topLeftX: topLeftXPts,
                              topLeftY: topLeftYPts,
                              effScale: effScale)
            }
            ForEach(regions.filter { $0.kind != .focalPlanePoint }) { region in
                box(for: region,
                    topLeftX: topLeftXPts,
                    topLeftY: topLeftYPts,
                    effScale: effScale)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func box(for region: AFRegion,
                     topLeftX: CGFloat,
                     topLeftY: CGFloat,
                     effScale: CGFloat) -> some View {
        let r = region.rect
        let w = max(r.width * effScale, 8)
        let h = max(r.height * effScale, 8)
        let x = topLeftX + r.midX * effScale
        let y = topLeftY + r.midY * effScale

        ZStack {
            Rectangle()
                .stroke(color(for: region.kind), lineWidth: 1.5)
                .frame(width: w, height: h)
            CornerBrackets()
                .stroke(color(for: region.kind), lineWidth: 2.5)
                .frame(width: w, height: h)
        }
        .position(x: x, y: y)
        .shadow(color: .black.opacity(0.6), radius: 2)
    }

    @ViewBuilder
    private func focalPlaneDot(for region: AFRegion,
                               topLeftX: CGFloat,
                               topLeftY: CGFloat,
                               effScale: CGFloat) -> some View {
        let r = region.rect
        let size = max(min(r.width, r.height) * effScale * 0.4, 5)
        let x = topLeftX + r.midX * effScale
        let y = topLeftY + r.midY * effScale

        Circle()
            .fill(color(for: region.kind).opacity(0.55))
            .overlay(Circle().stroke(color(for: region.kind), lineWidth: 1))
            .frame(width: size, height: size)
            .position(x: x, y: y)
            .shadow(color: .black.opacity(0.5), radius: 1)
    }

    private func color(for kind: AFRegion.Kind) -> Color {
        switch kind {
        case .primaryFocus:    return .yellow
        case .focalPlanePoint: return .yellow
        case .face:            return .green
        case .subject:         return .cyan
        }
    }
}

private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len = min(rect.width, rect.height) * 0.25
        // Top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        // Top-right
        p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        // Bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        // Bottom-left
        p.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        return p
    }
}
