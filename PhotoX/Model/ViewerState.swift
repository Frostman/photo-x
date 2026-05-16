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
    var currentPixelZoom: CGFloat = 1.0
    var isDecoding: Bool = false
    var errorMessage: String?

    let pipeline: DecodePipeline = DecodePipeline()

    func loadPair(_ pair: PhotoPair) async {
        pipeline.cache.clear()
        self.pair = pair
        self.currentImage = nil
        self.errorMessage = nil
        self.displayedVariant = .heif
        self.requestedVariant = .heif
        self.viewport = .identity
        self.currentPixelZoom = 1.0
        await applyRequestedVariant()
    }

    func toggleRequestedVariant() {
        guard pair != nil else { return }
        requestedVariant = (requestedVariant == .heif) ? .raw : .heif
        Task { await applyRequestedVariant() }
    }

    /// Cycles between ImageIO and LibRaw. The decoder is a RAW-only concern;
    /// HEIF always goes through ImageIO. If we're currently showing RAW, we
    /// re-decode immediately with the new decoder. If on HEIF, the change is
    /// silent — it kicks in next time the user goes to RAW.
    func cycleDecoder() {
        guard pair != nil else { return }
        decoder = (decoder == .imageIO) ? .libRaw : .imageIO
        if requestedVariant == .raw {
            Task { await applyRequestedVariant() }
        }
    }

    func setViewportToFit() {
        // Just request fit; the canvas emits the new pixelZoom back when the
        // viewport actually changes. If we're already at fit, the existing
        // value stays correct (don't pre-zero — that desynced the pill on a
        // second X press).
        viewport = .identity
    }

    /// Called by the canvas after gestures. Updates viewport + pixel zoom and
    /// kicks an auto-swap check.
    func updateViewportFromCanvas(_ vp: CanvasViewport, pixelZoom: CGFloat) {
        self.viewport = vp
        self.currentPixelZoom = pixelZoom
        Task { await maybeAutoSwap() }
    }

    /// Auto-swap is a one-way upgrade: HEIF → RAW when pixel zoom crosses 1.0.
    /// We never auto-revert to HEIF on zoom-out — once you've paid for the RAW
    /// decode it's cached, and flicker-y back-and-forth on resize is worse than
    /// staying on RAW. R still toggles manually.
    private func maybeAutoSwap() async {
        guard autoSwapEnabled, pair != nil else { return }
        if currentPixelZoom >= 1.0, requestedVariant == .heif {
            requestedVariant = .raw
            await applyRequestedVariant()
        }
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
            guard variant == self.requestedVariant, chosenDecoder == self.decoder else { return }
            self.currentImage = decoded
            self.displayedVariant = variant
        } catch {
            Log.app.error("applyRequestedVariant: \(String(describing: error), privacy: .public)")
            self.errorMessage = String(describing: error)
        }
    }
}
