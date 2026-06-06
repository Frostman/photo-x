import AppKit
import SwiftUI

/// SwiftUI root for the external-display NSWindow. Reads the active
/// presenter through the injected `PresentationCoordinator` so screen
/// content rebinds instantly when another window takes over.
struct ExternalDisplayRootView: View {
    private var coordinator: PresentationCoordinator { .shared }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let presenter = coordinator.activePresenter {
                if let image = presenter.currentImage,
                   let key = presenter.currentImageKey {
                    ExternalImageCanvas(
                        cgImage: image.cgImage,
                        token: presenter.entry?.stem ?? "",
                        orientation: image.orientation,
                        decodeKey: key,
                        mainViewport: presenter.viewport,
                        mainPixelZoom: presenter.currentPixelZoom,
                        imagePixelSize: presenter.displayedPixelSize
                    )
                    .ignoresSafeArea()
                }
                ExternalInfoBar(state: presenter)
            }
        }
    }
}

/// Slim wrapper around `ImageCanvasView` with no overlays. Mirrors the
/// main canvas's zoom + pan proportionally, so the external display
/// always shows the same fraction of the photo at the same focal point
/// — regardless of how much smaller (or larger) the external window is.
/// Onlooker view only: no event capture, no callbacks.
private struct ExternalImageCanvas: View {
    let cgImage: CGImage
    let token: String
    let orientation: Int
    let decodeKey: DecodeKey
    let mainViewport: CanvasViewport
    let mainPixelZoom: CGFloat
    let imagePixelSize: CGSize

    var body: some View {
        GeometryReader { geom in
            let externalPixelSize = pixelSize(geom: geom)
            let viewport = ExternalViewportTransform.externalViewport(
                mainViewport: mainViewport,
                mainPixelZoom: mainPixelZoom,
                imagePixelSize: imagePixelSize,
                externalViewPixelSize: externalPixelSize
            )
            ImageCanvasView(
                image: cgImage,
                imageToken: token,
                imageOrientation: orientation,
                imageDecodeKey: decodeKey,
                viewport: viewport,
                showClipping: false,
                showPeaking: false,
                onViewportChange: { _, _ in },
                onImageDisplayed: { _, _ in }
            )
        }
    }

    /// Convert SwiftUI's point-sized GeometryProxy frame to device
    /// pixels using the screen the window is on (which IS the external
    /// display's NSScreen, so backingScaleFactor matches what the
    /// Metal layer renders into).
    private func pixelSize(geom: GeometryProxy) -> CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return CGSize(width: geom.size.width * scale,
                      height: geom.size.height * scale)
    }
}
