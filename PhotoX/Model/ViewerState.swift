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

    var currentHistogram: Histogram?
    private var histogramGeneration: Int = 0

    var currentExif: ExifSummary?
    private var exifGeneration: Int = 0

    var currentAFRegions: [AFRegion] = []
    var currentAFSettings: AFSettings = AFSettings()
    private var afGeneration: Int = 0

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
        self.currentExif = nil
        self.currentAFRegions = []
        self.currentAFSettings = AFSettings()
        kickOffExifLoad(for: pair)
        kickOffAFLoad(for: pair)
        await applyRequestedVariant()
    }

    func toggleAFOverlay() {
        overlays.afPoints.toggle()
    }

    private func kickOffAFLoad(for pair: PhotoPair) {
        afGeneration += 1
        let gen = afGeneration
        let url = pair.rawURL
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                ExifToolRunner.readAF(from: url)
            }.value
            guard let self else { return }
            guard self.afGeneration == gen else { return }
            self.currentAFRegions = data.regions
            self.currentAFSettings = data.settings
            Log.app.notice("AF regions loaded: \(data.regions.count) for \(pair.stem, privacy: .public)")
        }
    }

    private func kickOffExifLoad(for pair: PhotoPair) {
        exifGeneration += 1
        let gen = exifGeneration
        let url = pair.rawURL  // EXIF is read from the canonical RAW file
        Task { [weak self] in
            let exif = await Task.detached(priority: .utility) {
                ImageIOMetadata.read(from: url)
            }.value
            guard let self else { return }
            guard self.exifGeneration == gen else { return }
            self.currentExif = exif
        }
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
    func toggleClipping() {
        overlays.clipping.toggle()
    }

    func togglePeaking() {
        overlays.focusPeaking.toggle()
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

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

    private var lastAutoSwapPixelZoom: CGFloat = 0

    /// Auto-swap is a one-way upgrade fired ONLY on the upward crossing of
    /// pixel zoom past 1.0 — not while pixel zoom is sustained above 1.0.
    /// Otherwise toggling Z back to HEIF while zoomed in would immediately
    /// yank you back to RAW on the next canvas emit (e.g., when the image
    /// dimensions shift slightly between HEIF and LibRaw output).
    private func maybeAutoSwap() async {
        let prev = lastAutoSwapPixelZoom
        let curr = currentPixelZoom
        lastAutoSwapPixelZoom = curr

        guard autoSwapEnabled, pair != nil else { return }
        if curr >= 1.0 && prev < 1.0 && requestedVariant == .heif {
            Log.app.notice("auto-swap: HEIF → RAW (pz \(prev, format: .fixed(precision: 2)) → \(curr, format: .fixed(precision: 2)))")
            requestedVariant = .raw
            await applyRequestedVariant()
        }
    }

    private func kickOffHistogramCompute(for image: DecodedImage) {
        histogramGeneration += 1
        let gen = histogramGeneration
        let cgImage = image.cgImage
        Task { [weak self] in
            // Detached child runs the CPU work off main; .value returns us
            // here (MainActor), where weak self is safely accessed.
            let h = await Task.detached(priority: .utility) {
                HistogramComputer.compute(from: cgImage)
            }.value
            guard let self else { return }
            guard self.histogramGeneration == gen else { return }
            self.currentHistogram = h
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
            kickOffHistogramCompute(for: decoded)
        } catch {
            Log.app.error("applyRequestedVariant: \(String(describing: error), privacy: .public)")
            self.errorMessage = String(describing: error)
        }
    }
}
