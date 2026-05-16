import AppKit
import CoreGraphics
import SwiftUI

struct ImageCanvasView: NSViewRepresentable {
    let image: CGImage?
    let viewport: CanvasViewport
    let showClipping: Bool
    let showPeaking: Bool
    let onViewportChange: (CanvasViewport, CGFloat) -> Void

    @MainActor
    final class Coordinator {
        var lastImageID: ObjectIdentifier?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageCanvasNSView {
        let view = ImageCanvasNSView()
        view.onViewportChange = onViewportChange
        view.setViewportFromExternal(viewport)
        view.setShowClipping(showClipping)
        view.setShowPeaking(showPeaking)
        if let image {
            view.setImage(image)
            context.coordinator.lastImageID = ObjectIdentifier(image as AnyObject)
        }
        return view
    }

    func updateNSView(_ nsView: ImageCanvasNSView, context: Context) {
        PerfTracker.mark("ImageCanvasView.updateNSView called")
        nsView.onViewportChange = onViewportChange
        nsView.setViewportFromExternal(viewport)
        nsView.setShowClipping(showClipping)
        nsView.setShowPeaking(showPeaking)
        if let image {
            let id = ObjectIdentifier(image as AnyObject)
            if id != context.coordinator.lastImageID {
                PerfTracker.mark("updateNSView: image changed → nsView.setImage")
                nsView.setImage(image)
                context.coordinator.lastImageID = id
            }
        } else {
            context.coordinator.lastImageID = nil
        }
    }
}
