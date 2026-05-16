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

    let pipeline: DecodePipeline = DecodePipeline()

    /// Sets the active pair and decodes the HEIF preview (always start on HEIF).
    func loadPair(_ pair: PhotoPair) async {
        pipeline.cache.clear()
        self.pair = pair
        self.currentImage = nil
        self.errorMessage = nil
        self.displayedVariant = .heif
        self.requestedVariant = .heif
        await applyRequestedVariant()
    }

    /// Flips requestedVariant between heif and raw and triggers decode.
    func toggleRequestedVariant() {
        guard pair != nil else { return }
        requestedVariant = (requestedVariant == .heif) ? .raw : .heif
        Task { await applyRequestedVariant() }
    }

    private func applyRequestedVariant() async {
        guard let pair else { return }
        let variant = requestedVariant
        let chosenDecoder = decoder
        self.errorMessage = nil
        self.isDecoding = true
        defer { isDecoding = false }

        do {
            let decoded = try await pipeline.decode(pair: pair, variant: variant, decoder: chosenDecoder)
            // If user toggled again while we were decoding, ignore stale result.
            guard variant == self.requestedVariant, chosenDecoder == self.decoder else { return }
            self.currentImage = decoded
            self.displayedVariant = variant
        } catch {
            Log.app.error("applyRequestedVariant: \(String(describing: error), privacy: .public)")
            self.errorMessage = String(describing: error)
        }
    }
}
