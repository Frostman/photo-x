import AppKit
import SwiftUI

/// Draws the experimental sharpness heatmap over the canvas at the
/// same fit/zoom as the photo. Heatmap data is a CGImage at tile
/// resolution (e.g. 64 × N); SwiftUI stretches it to fit the photo
/// area. Identical viewport math to `AFPointOverlay` — keep these
/// two in sync if the canvas transform changes.
struct SharpnessHeatmapOverlay: View {
    let image: CGImage
    let imagePixelSize: CGSize
    let viewport: CanvasViewport

    var body: some View {
        GeometryReader { geom in
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let canvas = geom.size

            let fit = min(canvas.width / imagePixelSize.width,
                          canvas.height / imagePixelSize.height)
            let effScale = fit * viewport.scale

            let offsetXPts = viewport.offset.x / scale
            let offsetYPts = viewport.offset.y / scale

            let imageWPts = imagePixelSize.width * effScale
            let imageHPts = imagePixelSize.height * effScale

            let centerXPts = canvas.width / 2 + offsetXPts
            let centerYPts = canvas.height / 2 - offsetYPts

            let topLeftXPts = centerXPts - imageWPts / 2
            let topLeftYPts = centerYPts - imageHPts / 2

            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.medium)
                .frame(width: imageWPts, height: imageHPts)
                .offset(x: topLeftXPts, y: topLeftYPts)
                .allowsHitTesting(false)
                .accessibilityIdentifier("canvas.sharpnessHeatmap")
        }
        .allowsHitTesting(false)
    }
}
