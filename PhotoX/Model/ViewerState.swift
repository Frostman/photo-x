import Observation
import SwiftUI

@MainActor
@Observable
final class ViewerState {
    var shoot: Shoot?
    var currentIndex: Int = 0

    var pair: PhotoPair? {
        guard let shoot, shoot.pairs.indices.contains(currentIndex) else { return nil }
        return shoot.pairs[currentIndex]
    }

    var decoder: DecoderChoice = .imageIO

    var displayedVariant: ImageVariant = .heif
    var requestedVariant: ImageVariant = .heif
    var autoSwapEnabled: Bool = false

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
    private var pairAFData: [String: ExifToolRunner.AFData] = [:]
    private var afInflight: [String: Task<ExifToolRunner.AFData, Never>] = [:]

    var currentXMP: XMPSidecar = .empty
    private var xmpGeneration: Int = 0

    var currentPairFiles: PairFiles = .none

    struct PairFiles: Hashable, Sendable {
        var arw: Bool = false
        var hif: Bool = false
        var xmp: Bool = false
        static let none = PairFiles()
    }

    // Filmstrip
    var filmstripVisible: Bool = true
    var thumbnails: [String: CGImage] = [:]
    var pairXMPs: [String: XMPSidecar] = [:]
    private var shootMetadataTask: Task<Void, Never>?
    private var thumbnailRequestedFor: Set<String> = []

    let pipeline: DecodePipeline = DecodePipeline()

    /// Loads a shoot and focuses on a specific pair within it. Replaces the
    /// previous single-pair flow.
    func loadShoot(_ shoot: Shoot, focus: PhotoPair) async {
        pipeline.cache.clear()
        self.shoot = shoot
        self.currentIndex = shoot.index(of: focus) ?? 0
        self.thumbnails = [:]
        self.pairXMPs = [:]
        await applyCurrentPair(resetViewport: true)
        kickOffShootMetadata()
    }

    func toggleFilmstrip() {
        filmstripVisible.toggle()
    }

    /// Background-load XMP sidecars for every pair so filmstrip badges are
    /// correct. Batched writes to pairXMPs (every 100 items / 250 ms) so
    /// SwiftUI doesn't re-render a 5000-item ForEach on every single update.
    /// Thumbnails are loaded LAZILY — see requestThumbnail(for:).
    private func kickOffShootMetadata() {
        guard let shoot else { return }
        shootMetadataTask?.cancel()
        let pairs = shoot.pairs
        shootMetadataTask = Task(priority: .utility) { [weak self] in
            var batch: [(String, XMPSidecar)] = []
            var lastFlush = CFAbsoluteTimeGetCurrent()
            let flushSize = 100
            let flushIntervalSec: Double = 0.25

            for pair in pairs {
                if Task.isCancelled { return }
                let xmp = await Task.detached(priority: .utility) {
                    XMPSidecarReader.read(for: pair)
                }.value
                batch.append((pair.stem, xmp))

                let now = CFAbsoluteTimeGetCurrent()
                if batch.count >= flushSize || (now - lastFlush) > flushIntervalSec {
                    let snapshot = batch
                    batch.removeAll(keepingCapacity: true)
                    lastFlush = now
                    await self?.flushXMPBatch(snapshot)
                }
            }
            if !batch.isEmpty {
                await self?.flushXMPBatch(batch)
            }
        }
    }

    private func flushXMPBatch(_ items: [(String, XMPSidecar)]) {
        for (stem, xmp) in items {
            // Don't overwrite an optimistic user update. If the user has
            // already set a rating on this pair, our in-memory value is the
            // source of truth (and the disk write either landed or is in
            // flight). Either way, skipping is correct.
            if pairXMPs[stem] == nil {
                pairXMPs[stem] = xmp
            }
        }
    }

    /// Called by the filmstrip when a thumbnail cell appears. Loads the
    /// thumbnail off main and caches it. Deduped — a second request for the
    /// same pair is a no-op while the first is in flight.
    func requestThumbnail(for pair: PhotoPair) {
        guard thumbnails[pair.stem] == nil,
              !thumbnailRequestedFor.contains(pair.stem) else { return }
        thumbnailRequestedFor.insert(pair.stem)
        let heifURL = pair.heifURL
        Task { [weak self] in
            let thumb = await Task.detached(priority: .utility) {
                ThumbnailLoader.load(from: heifURL)
            }.value
            guard let self else { return }
            if let thumb {
                self.thumbnails[pair.stem] = thumb
            }
        }
    }

    /// Move to a new pair within the current shoot (clamped).
    func navigate(to index: Int) {
        guard let shoot, !shoot.isEmpty else { return }
        let clamped = max(0, min(index, shoot.pairs.count - 1))
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        PerfTracker.mark("ViewerState.navigate → spawning task")
        Task { await applyCurrentPair(resetViewport: false) }
    }

    func nextPair() { navigate(to: currentIndex + 1) }
    func previousPair() { navigate(to: currentIndex - 1) }
    func firstPair() { navigate(to: 0) }
    func lastPair() {
        guard let shoot, !shoot.isEmpty else { return }
        navigate(to: shoot.pairs.count - 1)
    }

    func toggleRequestedVariant() {
        guard pair != nil else { return }
        requestedVariant = (requestedVariant == .heif) ? .raw : .heif
        Task { await applyRequestedVariant() }
    }

    func toggleClipping() {
        overlays.clipping.toggle()
    }

    func togglePeaking() {
        overlays.focusPeaking.toggle()
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    func toggleAFOverlay() {
        overlays.afPoints.toggle()
    }

    /// Sets the star rating (1...5), clears it (nil), or marks rejected (-1).
    /// Updates UI optimistically; rolls back if the XMP write fails.
    func setRating(_ rating: Int?) {
        guard let pair else { return }
        let previous = currentXMP
        var updated = currentXMP
        updated.rating = rating
        currentXMP = updated
        pairXMPs[pair.stem] = updated
        currentPairFiles.xmp = true
        let capturedPair = pair

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try XMPSidecarWriter.updateRating(rating, for: capturedPair)
                }.value
                Log.app.notice("XMP write OK: \(capturedPair.stem, privacy: .public) rating=\(rating.map(String.init) ?? "nil", privacy: .public)")
            } catch {
                // Rollback. Only touch currentXMP if the user hasn't navigated
                // away — otherwise we'd clobber unrelated state.
                if self.pair?.id == capturedPair.id {
                    self.currentXMP = previous
                }
                self.pairXMPs[capturedPair.stem] = previous
                self.errorMessage = "Failed to write XMP for \(capturedPair.stem): \(String(describing: error))"
                Log.app.error("XMP write FAILED: \(capturedPair.stem, privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// R toggles rating between -1 (reject) and nil (clear). Anything else
    /// (existing star rating) is converted to rejected.
    func toggleReject() {
        let next: Int? = (currentXMP.rating == -1) ? nil : -1
        setRating(next)
    }

    /// Pressing the same star key again clears the rating. From any other
    /// state (different stars or reject), sets to the requested value.
    func toggleRating(_ rating: Int) {
        setRating(currentXMP.rating == rating ? nil : rating)
    }

    func cycleDecoder() {
        guard pair != nil else { return }
        decoder = (decoder == .imageIO) ? .libRaw : .imageIO
        if requestedVariant == .raw {
            Task { await applyRequestedVariant() }
        }
    }

    func setViewportToFit() {
        viewport = .identity
    }

    func updateViewportFromCanvas(_ vp: CanvasViewport, pixelZoom: CGFloat) {
        self.viewport = vp
        self.currentPixelZoom = pixelZoom
        Task { await maybeAutoSwap() }
    }

    private var lastAutoSwapPixelZoom: CGFloat = 0

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

    /// Apply everything for the current pair: clear stale per-pair state,
    /// kick off metadata loads, decode the HEIF preview, then warm the cache
    /// with the neighbors' HEIFs so ←/→ feels instant.
    private func applyCurrentPair(resetViewport: Bool) async {
        guard let pair else { return }
        PerfTracker.mark("applyCurrentPair entered")
        // Keep currentImage as-is so the previous frame stays on screen until
        // the new one decodes — avoids a flash to ProgressView (which would
        // tear down the ImageCanvasView and lose SwiftUI focus). The
        // metadata-side panels (XMP, EXIF, AF) DO clear, because they're
        // pair-specific and a brief blank is better than showing stale info.
        self.errorMessage = nil
        self.displayedVariant = .heif
        self.requestedVariant = .heif
        if resetViewport {
            self.viewport = .identity
            self.currentPixelZoom = 1.0
        }
        self.currentExif = nil
        self.currentAFRegions = []
        self.currentAFSettings = AFSettings()
        self.currentXMP = .empty
        self.currentPairFiles = pairFiles(for: pair)
        kickOffExifLoad(for: pair)
        kickOffAFLoad(for: pair)
        kickOffXMPLoad(for: pair)
        await applyRequestedVariant()
        prefetchNeighborHEIFs()
    }

    private func pairFiles(for pair: PhotoPair) -> PairFiles {
        let fm = FileManager.default
        let xmpURL = pair.rawURL.deletingPathExtension().appendingPathExtension("xmp")
        return PairFiles(
            arw: fm.fileExists(atPath: pair.rawURL.path),
            hif: fm.fileExists(atPath: pair.heifURL.path),
            xmp: fm.fileExists(atPath: xmpURL.path)
        )
    }

    private func kickOffXMPLoad(for pair: PhotoPair) {
        xmpGeneration += 1
        let gen = xmpGeneration
        let pairCopy = pair
        Task { [weak self] in
            let xmp = await Task.detached(priority: .utility) {
                XMPSidecarReader.read(for: pairCopy)
            }.value
            guard let self else { return }
            guard self.xmpGeneration == gen else { return }
            self.currentXMP = xmp
        }
    }

    /// Warm the pipeline cache with HEIFs for index ±1 so arrow-key
    /// navigation feels instant. Best-effort; we ignore failures.
    private func prefetchNeighborHEIFs() {
        guard let shoot else { return }
        let neighborIndices = [currentIndex - 1, currentIndex + 1]
            .filter { shoot.pairs.indices.contains($0) }
        for idx in neighborIndices {
            let neighbor = shoot.pairs[idx]
            Task { [weak self] in
                _ = try? await self?.pipeline.decode(
                    pair: neighbor, variant: .heif, decoder: .imageIO
                )
            }
            // Warm the AF cache too — one exiftool call per neighbor, off main,
            // deduped against any concurrent foreground request via loadAFData.
            Task(priority: .utility) { [weak self] in
                _ = await self?.loadAFData(for: neighbor)
            }
        }
    }

    private func kickOffExifLoad(for pair: PhotoPair) {
        exifGeneration += 1
        let gen = exifGeneration
        let url = pair.rawURL
        Task { [weak self] in
            let exif = await Task.detached(priority: .utility) {
                ImageIOMetadata.read(from: url)
            }.value
            guard let self else { return }
            guard self.exifGeneration == gen else { return }
            self.currentExif = exif
        }
    }

    private func kickOffAFLoad(for pair: PhotoPair) {
        afGeneration += 1
        let gen = afGeneration
        Task { [weak self] in
            guard let self else { return }
            let data = await self.loadAFData(for: pair)
            guard self.afGeneration == gen else { return }
            self.currentAFRegions = data.regions
            self.currentAFSettings = data.settings
            Log.app.notice("AF regions loaded: \(data.regions.count) for \(pair.stem, privacy: .public)")
        }
    }

    /// Shared loader for AF data. Returns from cache when available, dedups
    /// in-flight requests so foreground + prefetch for the same pair don't
    /// spawn two exiftool calls.
    func loadAFData(for pair: PhotoPair) async -> ExifToolRunner.AFData {
        if let cached = pairAFData[pair.stem] {
            return cached
        }
        if let existing = afInflight[pair.stem] {
            return await existing.value
        }
        let url = pair.rawURL
        let stem = pair.stem
        let task = Task<ExifToolRunner.AFData, Never>(priority: .utility) {
            await Task.detached(priority: .utility) {
                ExifToolRunner.readAF(from: url)
            }.value
        }
        afInflight[stem] = task
        defer { afInflight[stem] = nil }
        let data = await task.value
        pairAFData[stem] = data
        return data
    }

    private func kickOffHistogramCompute(for image: DecodedImage) {
        histogramGeneration += 1
        let gen = histogramGeneration
        let cgImage = image.cgImage
        Task { [weak self] in
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
            PerfTracker.mark("about to await pipeline.decode")
            let decoded = try await pipeline.decode(pair: pair, variant: variant, decoder: chosenDecoder)
            PerfTracker.mark("pipeline.decode returned")
            guard variant == self.requestedVariant, chosenDecoder == self.decoder else { return }
            self.currentImage = decoded
            PerfTracker.mark("currentImage set")
            self.displayedVariant = variant
            kickOffHistogramCompute(for: decoded)
        } catch {
            Log.app.error("applyRequestedVariant: \(String(describing: error), privacy: .public)")
            self.errorMessage = String(describing: error)
        }
    }
}
