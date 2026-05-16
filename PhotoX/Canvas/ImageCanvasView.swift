import AppKit
import CoreGraphics
import SwiftUI

struct ImageCanvasView: NSViewRepresentable {
    let image: CGImage?
    let viewport: CanvasViewport
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
        if let image {
            view.setImage(image)
            context.coordinator.lastImageID = ObjectIdentifier(image as AnyObject)
        }
        return view
    }

    func updateNSView(_ nsView: ImageCanvasNSView, context: Context) {
        nsView.onViewportChange = onViewportChange
        nsView.setViewportFromExternal(viewport)
        if let image {
            let id = ObjectIdentifier(image as AnyObject)
            if id != context.coordinator.lastImageID {
                nsView.setImage(image)
                context.coordinator.lastImageID = id
            }
        } else {
            context.coordinator.lastImageID = nil
        }
    }
}
