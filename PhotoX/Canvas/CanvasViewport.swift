import CoreGraphics
import Foundation

struct CanvasViewport: Hashable, Sendable {
    var scale: CGFloat = 1.0
    var offset: CGPoint = .zero

    static let identity = CanvasViewport()

    /// Computes the scale that fits `imagePixelSize` inside `viewPixelSize` letterboxed.
    static func fitScale(imagePixelSize: CGSize, viewPixelSize: CGSize) -> CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              viewPixelSize.width > 0, viewPixelSize.height > 0
        else { return 1.0 }
        let sx = viewPixelSize.width / imagePixelSize.width
        let sy = viewPixelSize.height / imagePixelSize.height
        return min(sx, sy)
    }

    /// "Pixel zoom" — 1.0 means one image pixel equals one device pixel.
    /// `contentScale` is the layer's contentsScale (typically 2.0 on Retina).
    func pixelZoom(imagePixelSize: CGSize, viewPixelSize: CGSize, contentScale: CGFloat) -> CGFloat {
        let fit = Self.fitScale(imagePixelSize: imagePixelSize, viewPixelSize: viewPixelSize)
        // `scale` is multiplicative on top of fit. fit*scale converts image-pixels to layer-points;
        // multiplied by contentScale gives device-pixels per image-pixel.
        return fit * scale * contentScale
    }
}
