import CoreGraphics
import Foundation

/// Pure value transform that takes the main canvas's viewport and
/// produces an equivalent one for the external display, so both windows
/// show visually the same fraction of the photo at the same focal
/// point — even when the external window is much smaller than the main
/// canvas.
///
/// `CanvasViewport.scale` is already proportional (1.0 = fit), so it
/// copies directly. `offset` is in device pixels, so it has to be
/// rescaled by the ratio of fit-scales between the two windows.
enum ExternalViewportTransform {

    /// - Parameters:
    ///   - mainViewport: The main canvas's current viewport.
    ///   - mainPixelZoom: The main canvas's `pixelZoom`
    ///     (= main fit × `mainViewport.scale`), as reported through
    ///     `ViewerState.currentPixelZoom`.
    ///   - imagePixelSize: Displayed image's pixel size in display
    ///     orientation (`ViewerState.displayedPixelSize`).
    ///   - externalViewPixelSize: The external NSView's drawable size
    ///     in device pixels.
    ///
    /// - Returns: A viewport that, when applied to the external view,
    ///   shows the same fraction of the photo at the same focal point
    ///   as the main canvas. Returns `.identity` when any input is
    ///   degenerate (zero image size, zero pixelZoom, zero external
    ///   size) — i.e. during the warm-up window before
    ///   `commitDisplayed` has reported back.
    static func externalViewport(
        mainViewport: CanvasViewport,
        mainPixelZoom: CGFloat,
        imagePixelSize: CGSize,
        externalViewPixelSize: CGSize
    ) -> CanvasViewport {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              externalViewPixelSize.width > 0, externalViewPixelSize.height > 0,
              mainPixelZoom > 0, mainViewport.scale > 0
        else {
            return .identity
        }

        let mainFit = mainPixelZoom / mainViewport.scale
        let externalFit = CanvasViewport.fitScale(
            imagePixelSize: imagePixelSize,
            viewPixelSize: externalViewPixelSize
        )
        guard mainFit > 0, externalFit > 0 else { return .identity }

        let ratio = externalFit / mainFit
        return CanvasViewport(
            scale: mainViewport.scale,
            offset: CGPoint(
                x: mainViewport.offset.x * ratio,
                y: mainViewport.offset.y * ratio
            )
        )
    }
}
