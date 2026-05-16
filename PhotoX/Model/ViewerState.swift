import Observation
import SwiftUI

@MainActor
@Observable
final class ViewerState {
    var pair: PhotoPair?
    var decoder: DecoderChoice = .imageIO

    var displayedVariant: ImageVariant = .heif
    var requestedVariant: ImageVariant = .heif
    var autoSwapEnabled: Bool = true

    var overlays: OverlayToggles = .init()
    var sidebarVisible: Bool = true

    var viewport: CanvasViewport = .identity
    var currentImage: DecodedImage?
    var isDecoding: Bool = false
    var errorMessage: String?

    var lastDecodeMS: [DecoderChoice: Double] = [:]
}
