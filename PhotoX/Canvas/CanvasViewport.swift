import CoreGraphics
import Foundation

struct CanvasViewport: Hashable, Sendable {
    var scale: CGFloat = 1.0    // multiplier on top of fit (1.0 = fit-to-window)
    var offset: CGPoint = .zero // device-pixel pan offset; +x right, +y up

    static let identity = CanvasViewport()
    /// Floor at fit — the user can never zoom OUT below the fit-to-window size.
    /// Pinching out at fit is a no-op.
    static let minScale: CGFloat = 1.0
    static let maxScale: CGFloat = 64

    /// Scale that fits `imagePixelSize` inside `viewPixelSize` letterboxed.
    static func fitScale(imagePixelSize: CGSize, viewPixelSize: CGSize) -> CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              viewPixelSize.width > 0, viewPixelSize.height > 0
        else { return 1.0 }
        return min(viewPixelSize.width / imagePixelSize.width,
                   viewPixelSize.height / imagePixelSize.height)
    }

    /// 1.0 means one image pixel == one device pixel.
    func pixelZoom(imagePixelSize: CGSize, viewPixelSize: CGSize) -> CGFloat {
        Self.fitScale(imagePixelSize: imagePixelSize, viewPixelSize: viewPixelSize) * scale
    }

    /// Zoom around a focal point (device pixels, +y up).
    func zoomed(by factor: CGFloat, around focal: CGPoint, viewSize: CGSize) -> CanvasViewport {
        let newScale = clamp(scale * factor, Self.minScale, Self.maxScale)
        guard scale > 0 else { return self }
        let ratio = newScale / scale
        let cx = viewSize.width / 2
        let cy = viewSize.height / 2
        let dx = (focal.x - cx) * (1 - ratio) + offset.x * ratio
        let dy = (focal.y - cy) * (1 - ratio) + offset.y * ratio
        return CanvasViewport(scale: newScale, offset: CGPoint(x: dx, y: dy))
    }

    func panned(by delta: CGPoint) -> CanvasViewport {
        CanvasViewport(scale: scale, offset: CGPoint(x: offset.x + delta.x, y: offset.y + delta.y))
    }

    /// Viewport that puts one image pixel onto one device pixel, centered.
    static func oneToOne(imagePixelSize: CGSize, viewPixelSize: CGSize) -> CanvasViewport {
        let fit = fitScale(imagePixelSize: imagePixelSize, viewPixelSize: viewPixelSize)
        guard fit > 0 else { return .identity }
        return CanvasViewport(scale: 1.0 / fit, offset: .zero)
    }
}

private func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}
