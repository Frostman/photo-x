import CoreGraphics
import Foundation

struct CanvasViewport: Hashable, Sendable {
    var scale: CGFloat = 1.0    // multiplier on top of fit (1.0 = fit-to-window)
    var offset: CGPoint = .zero // device-pixel pan offset; +x right, +y up

    static let identity = CanvasViewport()
    /// Floor at half the fit size. clampedOffset() forces offset to 0 on any
    /// axis where the image is smaller than the viewport, so anything below
    /// scale 1.0 stays centered and can't be panned around.
    static let minScale: CGFloat = 0.5
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

    /// Clamp `offset` so the image always fully covers (or is centered within)
    /// the viewport: no empty space appears on any side, and the user can't
    /// drag the image off the visible area. When the image is smaller than
    /// the viewport on an axis (only happens at scale == 1.0 / fit), the
    /// offset on that axis is forced to 0 so the image stays centered.
    func clampedOffset(imagePixelSize: CGSize, viewPixelSize: CGSize) -> CanvasViewport {
        let fit = Self.fitScale(imagePixelSize: imagePixelSize, viewPixelSize: viewPixelSize)
        let effScale = fit * scale
        let imgW = imagePixelSize.width * effScale
        let imgH = imagePixelSize.height * effScale
        let maxX = max(0, (imgW - viewPixelSize.width) / 2)
        let maxY = max(0, (imgH - viewPixelSize.height) / 2)
        let cx = min(max(offset.x, -maxX), maxX)
        let cy = min(max(offset.y, -maxY), maxY)
        return CanvasViewport(scale: scale, offset: CGPoint(x: cx, y: cy))
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
