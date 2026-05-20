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
    /// The `DecodeKey` that produced `image`. The renderer uses it to
    /// check `MTLTextureCache` — back-and-forth nav to a cached pair
    /// becomes a synchronous bind (no async upload).
    let imageDecodeKey: DecodeKey
    let viewport: CanvasViewport
    let showClipping: Bool
    let showPeaking: Bool
    let onViewportChange: (CanvasViewport, CGFloat) -> Void
    let onImageDisplayed: (String, CGSize) -> Void

    @MainActor
    final class Coordinator {
        var lastImageID: ObjectIdentifier?
        /// We trigger `setImage` on EITHER a new CGImage instance OR a
        /// new DecodeKey. The key-change-only case covers the
        /// "applyRequestedVariant fast path" where `currentImage` was
        /// left pointing at the previous pair (we skipped the decode
        /// because the texture was already cached) but the key
        /// advanced to the new pair. The renderer's cache-hit setImage
        /// path ignores the passed CGImage and binds the cached
        /// texture by key, so the stale CGImage is harmless.
        var lastKey: DecodeKey?
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
            view.setImage(image, token: imageToken, orientation: imageOrientation, key: imageDecodeKey)
            context.coordinator.lastImageID = ObjectIdentifier(image as AnyObject)
            context.coordinator.lastKey = imageDecodeKey
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
            // Trigger setImage on image-identity change OR key change.
            // The key-only-change path is the texture-cache fast path
            // where ViewerState skipped pipeline.decode but advanced
            // currentImageKey to the new pair — the renderer's
            // cache-hit setImage will bind the cached texture by key
            // (ignoring the passed CGImage).
            if id != context.coordinator.lastImageID ||
               imageDecodeKey != context.coordinator.lastKey
            {
                PerfTracker.mark("updateNSView: image/key changed → nsView.setImage")
                nsView.setImage(image, token: imageToken, orientation: imageOrientation, key: imageDecodeKey)
                context.coordinator.lastImageID = id
                context.coordinator.lastKey = imageDecodeKey
            }
        } else {
            context.coordinator.lastImageID = nil
            context.coordinator.lastKey = nil
        }
    }
}
