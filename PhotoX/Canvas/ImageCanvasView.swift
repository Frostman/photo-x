import AppKit
import CoreGraphics
import SwiftUI

struct ImageCanvasView: NSViewRepresentable {
    let image: CGImage?
    /// Opaque identifier (PhotoX uses the pair stem) echoed back via
    /// `onImageDisplayed` when the texture for `image` is bound. Lets
    /// the model commit displayed-pair state in lock-step with the new
    /// pixels appearing on screen — keeps filmstrip selection / AF
    /// overlay / sidebar EXIF synced with what the user actually sees.
    let imageToken: String
    /// EXIF orientation of `image` (1–8). Passed through to the
    /// renderer so portraits rotate via shader UV transform rather
    /// than a CPU pixel pass.
    let imageOrientation: Int
    let viewport: CanvasViewport
    let showClipping: Bool
    let showPeaking: Bool
    let onViewportChange: (CanvasViewport, CGFloat) -> Void
    let onImageDisplayed: (String, CGSize) -> Void

    @MainActor
    final class Coordinator {
        var lastImageID: ObjectIdentifier?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageCanvasNSView {
        let view = ImageCanvasNSView()
        view.onViewportChange = onViewportChange
        view.onImageDisplayed = onImageDisplayed
        view.setViewportFromExternal(viewport)
        view.setShowClipping(showClipping)
        view.setShowPeaking(showPeaking)
        if let image {
            view.setImage(image, token: imageToken, orientation: imageOrientation)
            context.coordinator.lastImageID = ObjectIdentifier(image as AnyObject)
        }
        return view
    }

    func updateNSView(_ nsView: ImageCanvasNSView, context: Context) {
        PerfTracker.mark("ImageCanvasView.updateNSView called")
        nsView.onViewportChange = onViewportChange
        nsView.onImageDisplayed = onImageDisplayed
        nsView.setViewportFromExternal(viewport)
        nsView.setShowClipping(showClipping)
        nsView.setShowPeaking(showPeaking)
        if let image {
            let id = ObjectIdentifier(image as AnyObject)
            if id != context.coordinator.lastImageID {
                PerfTracker.mark("updateNSView: image changed → nsView.setImage")
                nsView.setImage(image, token: imageToken, orientation: imageOrientation)
                context.coordinator.lastImageID = id
            }
        } else {
            context.coordinator.lastImageID = nil
        }
    }
}
