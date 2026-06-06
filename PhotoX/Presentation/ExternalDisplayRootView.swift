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
                        decodeKey: key
                    )
                    .ignoresSafeArea()
                }
                ExternalInfoBar(state: presenter)
            }
        }
    }
}

/// Slim wrapper around `ImageCanvasView` with no zoom / pan / overlays —
/// fit-to-window letterboxed render driven entirely by the source
/// `ViewerState`. Onlooker view only: no event capture, no callbacks.
private struct ExternalImageCanvas: View {
    let cgImage: CGImage
    let token: String
    let orientation: Int
    let decodeKey: DecodeKey

    var body: some View {
        ImageCanvasView(
            image: cgImage,
            imageToken: token,
            imageOrientation: orientation,
            imageDecodeKey: decodeKey,
            viewport: .identity,
            showClipping: false,
            showPeaking: false,
            onViewportChange: { _, _ in },
            onImageDisplayed: { _, _ in }
        )
    }
}
