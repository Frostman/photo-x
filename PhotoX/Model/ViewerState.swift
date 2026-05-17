import Observation
import SwiftUI

/// Where a rating/label/reject action originated from. Each source has its
/// own auto-advance setting so power-users can opt into shortcut-only
/// auto-advance while keeping sidebar clicks deliberate (or vice-versa).
enum RatingInputSource {
    case keyboard
    case sidebar
}

/// Order in which pairs appear in the filmstrip + navigation. Filmstrip is
/// horizontal, so the directional arrows on the score modes show where the
/// higher-rated images land: → means highest-on-right, ← means highest-on-left.
enum SortMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case name
    case scoreAscending   // 1★ on the left, 5★ on the right
    case scoreDescending  // 5★ on the left, 1★ on the right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:             return "Name"
        case .scoreAscending:   return "Score"
        case .scoreDescending:  return "Score"
        }
    }

    /// Icon shown in the status bar pill / menu rows.
    var systemImage: String {
        switch self {
        case .name:             return "textformat"
        case .scoreAscending:   return "arrow.right"
        case .scoreDescending:  return "arrow.left"
        }
    }
}

@MainActor
@Observable
final class ViewerState {
    var shoot: Shoot?
    var currentIndex: Int = 0

    var pair: PhotoPair? {
        let pairs = sortedPairs
        guard pairs.indices.contains(currentIndex) else { return nil }
        return pairs[currentIndex]
    }

    var decoder: DecoderChoice = .imageIO

    var displayedVariant: ImageVariant = .heif
    var requestedVariant: ImageVariant = .heif
    var autoSwapEnabled: Bool

    var overlays: OverlayToggles = .init()
    var sidebarVisible: Bool

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

    /// Bumped on every shoot teardown (closeShoot, loadShoot). Any background
    /// task that might write into per-shoot state (thumbnails, pairXMPs,
    /// pairAFData) captures this at spawn time and checks it before applying
    /// its result. This drops stale writes from tasks that finish after the
    /// user closed the shoot or switched folders.
    private var shootGeneration: Int = 0

    var perfStats: PerfStats = PerfStats()

    struct PerfStats: Hashable, Sendable {
        var imageMS: Double?
        var imageCached: Bool = false
        var afMS: Double?
        var afCached: Bool = false
        var xmpMS: Double?
    }

    var currentPairFiles: PairFiles = .none

    struct PairFiles: Hashable, Sendable {
        var arw: Bool = false
        var hif: Bool = false
        var xmp: Bool = false
        static let none = PairFiles()
    }

    // Filmstrip
    var filmstripVisible: Bool

    /// Sort order for the filmstrip + navigation. Session-only (not persisted).
    /// Mutating this through `setSortMode(_:)` preserves the currently-focused
    /// pair across the reorder. Direct assignment (e.g. via a Picker binding)
    /// does NOT remap currentIndex — always go through setSortMode.
    private(set) var sortMode: SortMode = .name

    /// `shoot.pairs` re-ordered per `sortMode`. Recomputed on every access;
    /// for the largest shoots we test against (~5 k pairs) that's <10 ms.
    /// Score-mode ties break on stem so the order is deterministic.
    var sortedPairs: [PhotoPair] {
        guard let shoot else { return [] }
        switch sortMode {
        case .name:
            return shoot.pairs
        case .scoreAscending:
            return shoot.pairs.sorted { a, b in
                let sa = sortScore(of: a)
                let sb = sortScore(of: b)
                if sa != sb { return sa < sb }
                return a.stem < b.stem
            }
        case .scoreDescending:
            return shoot.pairs.sorted { a, b in
                let sa = sortScore(of: a)
                let sb = sortScore(of: b)
                if sa != sb { return sa > sb }
                return a.stem < b.stem
            }
        }
    }

    /// Numeric score for sort comparisons. Rejected (-1) sinks below unrated
    /// (0) in asc mode and stays at the bottom in desc mode by sort symmetry.
    private func sortScore(of pair: PhotoPair) -> Int {
        pairXMPs[pair.stem]?.rating ?? 0
    }

    /// Change the sort mode while preserving which pair is currently focused.
    /// Use this instead of writing to `sortMode` directly — otherwise the
    /// pair under `currentIndex` will shift to whatever pair happens to land
    /// at that index in the new order.
    func setSortMode(_ newMode: SortMode) {
        guard newMode != sortMode else { return }
        let currentStem = pair?.stem
        sortMode = newMode
        if let stem = currentStem,
           let idx = sortedPairs.firstIndex(where: { $0.stem == stem }) {
            currentIndex = idx
        }
    }

    // Filters (session-only — not persisted). On = category is included
    // in the filmstrip + navigation.
    var showRejected: Bool = true
    var showUnrated: Bool = true
    /// Which star ratings (1...5) to include. Default: all. Toggling individual
    /// stars off in the status bar replaces the previous single "Rated" flag.
    var showStars: Set<Int> = [1, 2, 3, 4, 5]

    enum RatingCategory: Sendable, Hashable {
        case rejected
        case rated(stars: Int)   // 1...5
        case unrated
    }

    func ratingCategory(for stem: String) -> RatingCategory {
        let xmp = pairXMPs[stem] ?? .empty
        if xmp.isReject { return .rejected }
        if let stars = xmp.starCount, stars > 0 { return .rated(stars: stars) }
        return .unrated
    }

    func isVisible(_ pair: PhotoPair) -> Bool {
        switch ratingCategory(for: pair.stem) {
        case .rejected:           return showRejected
        case .rated(let stars):   return showStars.contains(stars)
        case .unrated:            return showUnrated
        }
    }

    /// Counts across the entire shoot. O(N) per call; ok for filmstrip-scale
    /// shoots, may want memoising if we ever go past tens of thousands.
    /// `stars[i]` (i = 1...5) holds the per-star count; `rated` is the sum.
    var shootStats: (rated: Int, rejected: Int, unrated: Int, stars: [Int: Int], total: Int) {
        guard let shoot else { return (0, 0, 0, [:], 0) }
        var rated = 0, rejected = 0, unrated = 0
        var stars: [Int: Int] = [:]
        for pair in shoot.pairs {
            switch ratingCategory(for: pair.stem) {
            case .rated(let n):
                rated += 1
                stars[n, default: 0] += 1
            case .rejected:
                rejected += 1
            case .unrated:
                unrated += 1
            }
        }
        return (rated, rejected, unrated, stars, shoot.pairs.count)
    }

    /// How many pairs the user is currently looking at (= sum of enabled
    /// categories). Derived from shootStats + show-* toggles.
    var shownCount: Int {
        let s = shootStats
        var n = 0
        for (stars, count) in s.stars where showStars.contains(stars) { n += count }
        if showRejected { n += s.rejected }
        if showUnrated  { n += s.unrated }
        return n
    }
    var thumbnails: [String: CGImage] = [:]
    var pairXMPs: [String: XMPSidecar] = [:]
    private var shootMetadataTask: Task<Void, Never>?
    private var thumbnailRequestedFor: Set<String> = []

    let pipeline: DecodePipeline = DecodePipeline()

    /// Read live from UserDefaults so changes in Settings take effect on the
    /// next rating action — no app restart required.
    private func autoAdvanceAfterRating(source: RatingInputSource) -> Bool {
        switch source {
        case .keyboard: return UserDefaults.standard.bool(forKey: SettingsKey.autoAdvance)
        case .sidebar:  return UserDefaults.standard.bool(forKey: SettingsKey.autoAdvanceSidebar)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.sidebarVisible = defaults.object(forKey: SettingsKey.sidebarVisible) as? Bool
            ?? SettingsKey.Defaults.sidebarVisible
        self.filmstripVisible = defaults.object(forKey: SettingsKey.filmstripVisible) as? Bool
            ?? SettingsKey.Defaults.filmstripVisible
        self.autoSwapEnabled = defaults.object(forKey: SettingsKey.autoSwapToRAW) as? Bool
            ?? SettingsKey.Defaults.autoSwapToRAW
        var initialOverlays = OverlayToggles()
        initialOverlays.afPoints = defaults.object(forKey: SettingsKey.afOverlayVisible) as? Bool
            ?? SettingsKey.Defaults.afOverlayVisible
        self.overlays = initialOverlays
    }

    /// Loads a shoot and focuses on a specific pair within it. Replaces the
    /// previous single-pair flow.
    func loadShoot(_ shoot: Shoot, focus: PhotoPair) async {
        resetForShootSwitch()
        self.shoot = shoot
        self.currentIndex = shoot.index(of: focus) ?? 0
        RecentShoots.shared.add(shoot.folderURL.path)
        await applyCurrentPair(resetViewport: true)
        kickOffShootMetadata()
    }

    /// Drop the current shoot and return to the empty starter state.
    func closeShoot() {
        resetForShootSwitch()
        shoot = nil
    }

    /// Shared teardown for closeShoot + loadShoot. Cancels all trackable
    /// in-flight tasks, clears every per-shoot cache, resets all view state
    /// to identity, and bumps every generation counter so any task that
    /// completes after this call drops its result (see shootGeneration).
    private func resetForShootSwitch() {
        // 1) Invalidate any in-flight task that captured an older generation.
        shootGeneration &+= 1
        xmpGeneration &+= 1
        exifGeneration &+= 1
        afGeneration &+= 1
        histogramGeneration &+= 1

        // 2) Cancel the trackable long-running tasks.
        shootMetadataTask?.cancel()
        shootMetadataTask = nil
        afInflight.values.forEach { $0.cancel() }
        afInflight.removeAll()

        // 3) Clear all caches.
        pipeline.cache.clear()
        thumbnails.removeAll()
        thumbnailRequestedFor.removeAll()
        pairXMPs.removeAll()
        pairAFData.removeAll()

        // 4) Reset per-pair UI state.
        currentIndex = 0
        currentImage = nil
        currentXMP = .empty
        currentExif = nil
        currentHistogram = nil
        currentAFRegions = []
        currentAFSettings = AFSettings()
        currentPairFiles = .none
        perfStats = PerfStats()
        errorMessage = nil
        isDecoding = false
        viewport = .identity
        currentPixelZoom = 1.0
        displayedVariant = .heif
        requestedVariant = .heif
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
        let gen = shootGeneration
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
                    await self?.flushXMPBatch(snapshot, generation: gen)
                }
            }
            if !batch.isEmpty {
                await self?.flushXMPBatch(batch, generation: gen)
            }
        }
    }

    private func flushXMPBatch(_ items: [(String, XMPSidecar)], generation: Int) {
        // Drop a flush that lands after the shoot was closed/switched.
        guard shootGeneration == generation else { return }
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
        let gen = shootGeneration
        Task { [weak self] in
            let thumb = await Task.detached(priority: .utility) {
                ThumbnailLoader.load(from: heifURL)
            }.value
            guard let self, self.shootGeneration == gen else { return }
            if let thumb {
                self.thumbnails[pair.stem] = thumb
            }
        }
    }

    /// Move to a new pair within the current shoot (clamped). Index is into
    /// `sortedPairs`, i.e. display order.
    func navigate(to index: Int) {
        let pairs = sortedPairs
        guard !pairs.isEmpty else { return }
        let clamped = max(0, min(index, pairs.count - 1))
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        PerfTracker.mark("ViewerState.navigate → spawning task")
        Task { await applyCurrentPair(resetViewport: false) }
    }

    func nextPair() {
        if let idx = nextVisibleIndex(from: currentIndex, direction: 1) {
            navigate(to: idx)
        }
    }
    func previousPair() {
        if let idx = nextVisibleIndex(from: currentIndex, direction: -1) {
            navigate(to: idx)
        }
    }
    func firstPair() {
        guard let shoot, !shoot.isEmpty else { return }
        // First visible from the front. If currentIndex is already 0 and visible,
        // nextVisibleIndex(from: -1, direction: +1) starts at 0.
        if let idx = nextVisibleIndex(from: -1, direction: 1) {
            navigate(to: idx)
        }
    }
    func lastPair() {
        let pairs = sortedPairs
        guard !pairs.isEmpty else { return }
        if let idx = nextVisibleIndex(from: pairs.count, direction: -1) {
            navigate(to: idx)
        }
    }

    /// Walk from `from` in `direction` (±1), skipping pairs filtered out by
    /// the current show-* toggles. Walks `sortedPairs` (display order).
    /// Returns nil if no visible pair lies in that direction.
    private func nextVisibleIndex(from: Int, direction: Int) -> Int? {
        let pairs = sortedPairs
        var i = from + direction
        while pairs.indices.contains(i) {
            if isVisible(pairs[i]) { return i }
            i += direction
        }
        return nil
    }

    /// Walk `steps` visible pairs (sign = direction). Used by ⌥+arrow.
    func navigate(by steps: Int) {
        guard steps != 0 else { return }
        let direction = steps > 0 ? 1 : -1
        var idx = currentIndex
        for _ in 0..<abs(steps) {
            guard let next = nextVisibleIndex(from: idx, direction: direction) else { break }
            idx = next
        }
        navigate(to: idx)
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
    func setRating(_ rating: Int?, source: RatingInputSource = .keyboard) {
        guard let pair else { return }
        let previous = currentXMP
        var updated = currentXMP
        updated.rating = rating
        currentXMP = updated
        pairXMPs[pair.stem] = updated
        currentPairFiles.xmp = true
        let capturedPair = pair

        // Auto-advance only on SET (non-nil) — clearing is usually a "fix
        // this mistake" action, not a decision worth moving past.
        if rating != nil, autoAdvanceAfterRating(source: source) {
            nextPair()
        }

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
    func toggleReject(source: RatingInputSource = .keyboard) {
        let next: Int? = (currentXMP.rating == -1) ? nil : -1
        setRating(next, source: source)
    }

    /// Pressing the same star key again clears the rating. From any other
    /// state (different stars or reject), sets to the requested value.
    func toggleRating(_ rating: Int, source: RatingInputSource = .keyboard) {
        setRating(currentXMP.rating == rating ? nil : rating, source: source)
    }

    /// Sets the XMP color label, or clears it (nil). Optimistic with rollback.
    func setLabel(_ label: String?, source: RatingInputSource = .keyboard) {
        guard let pair else { return }
        let previous = currentXMP
        var updated = currentXMP
        updated.label = label
        currentXMP = updated
        pairXMPs[pair.stem] = updated
        currentPairFiles.xmp = true
        let capturedPair = pair

        if label != nil, autoAdvanceAfterRating(source: source) {
            nextPair()
        }

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try XMPSidecarWriter.updateLabel(label, for: capturedPair)
                }.value
                Log.app.notice("XMP label write OK: \(capturedPair.stem, privacy: .public) label=\(label ?? "nil", privacy: .public)")
            } catch {
                if self.pair?.id == capturedPair.id {
                    self.currentXMP = previous
                }
                self.pairXMPs[capturedPair.stem] = previous
                self.errorMessage = "Failed to write XMP label for \(capturedPair.stem): \(String(describing: error))"
                Log.app.error("XMP label write FAILED: \(capturedPair.stem, privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Click same color again clears.
    func toggleLabel(_ label: String, source: RatingInputSource = .keyboard) {
        setLabel(currentXMP.label == label ? nil : label, source: source)
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
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { [weak self] in
            let xmp = await Task.detached(priority: .utility) {
                XMPSidecarReader.read(for: pairCopy)
            }.value
            guard let self else { return }
            guard self.xmpGeneration == gen else { return }
            self.currentXMP = xmp
            self.perfStats.xmpMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        }
    }

    /// Warm the pipeline cache with HEIFs for index ±1 so arrow-key
    /// navigation feels instant. Best-effort; we ignore failures.
    private func prefetchNeighborHEIFs() {
        let pairs = sortedPairs
        let neighborIndices = [currentIndex - 1, currentIndex + 1]
            .filter { pairs.indices.contains($0) }
        for idx in neighborIndices {
            let neighbor = pairs[idx]
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
        let wasCached = pairAFData[pair.stem] != nil
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { [weak self] in
            guard let self else { return }
            let data = await self.loadAFData(for: pair)
            guard self.afGeneration == gen else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            self.currentAFRegions = data.regions
            self.currentAFSettings = data.settings
            self.perfStats.afMS = ms
            self.perfStats.afCached = wasCached
            Log.app.notice("AF regions loaded: \(data.regions.count) for \(pair.stem, privacy: .public) in \(ms, format: .fixed(precision: 1)) ms (cached=\(wasCached))")
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
        let gen = shootGeneration
        let task = Task<ExifToolRunner.AFData, Never>(priority: .utility) {
            await Task.detached(priority: .utility) {
                ExifToolRunner.readAF(from: url)
            }.value
        }
        afInflight[stem] = task
        defer { afInflight[stem] = nil }
        let data = await task.value
        // If the shoot was closed/switched while we were waiting on exiftool,
        // don't pollute the (now-cleared) cache for the next shoot.
        guard shootGeneration == gen else { return data }
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
            let wasCached = pipeline.isCached(pair: pair, variant: variant, decoder: chosenDecoder)
            let t0 = CFAbsoluteTimeGetCurrent()
            let decoded = try await pipeline.decode(pair: pair, variant: variant, decoder: chosenDecoder)
            let imageWallMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            PerfTracker.mark("pipeline.decode returned")
            guard variant == self.requestedVariant, chosenDecoder == self.decoder else { return }
            self.currentImage = decoded
            self.perfStats.imageMS = imageWallMS
            self.perfStats.imageCached = wasCached
            PerfTracker.mark("currentImage set")
            self.displayedVariant = variant
            kickOffHistogramCompute(for: decoded)
        } catch {
            Log.app.error("applyRequestedVariant: \(String(describing: error), privacy: .public)")
            self.errorMessage = String(describing: error)
        }
    }
}
