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
    /// Per-stem AF data cache. Populated EXCLUSIVELY by the indexer's
    /// exiftool pipeline (see `runExifPipeline`). Cleared on shoot switch.
    var pairAFData: [String: ExifToolRunner.AFData] = [:]

    var currentXMP: XMPSidecar = .empty
    private var xmpGeneration: Int = 0

    /// Bumped on every shoot teardown (closeShoot, loadShoot). Any background
    /// task that might write into per-shoot state (thumbnails, pairXMPs,
    /// pairAFData) captures this at spawn time and checks it before applying
    /// its result. This drops stale writes from tasks that finish after the
    /// user closed the shoot or switched folders.
    private var shootGeneration: Int = 0

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
    // MARK: - Indexer-populated caches
    //
    // The indexer (see `startIndexing`) is the SOLE writer for these — no
    // per-pair lazy fetches anywhere. `applyCurrentPair` reads them
    // synchronously; SwiftUI re-renders when the flush methods publish a
    // batch's results to the cache.

    var thumbnails: [String: CGImage] = [:]
    var pairXMPs: [String: XMPSidecar] = [:]
    /// Sony `SequenceNumber` per pair stem; filter-independent (every loaded
    /// pair has its raw number). Drives `burstIDByStem` for the filmstrip
    /// bracket overlay.
    var pairSequenceNumber: [String: Int] = [:]
    /// EXIF summary for the sidebar, indexed eagerly via the exiftool batch
    /// loader. Replaces the per-navigation ImageIO read.
    var pairExif: [String: ExifSummary] = [:]

    // MARK: - Indexing state

    enum IndexingStatus: Hashable, Sendable {
        case idle                           // no shoot loaded
        case indexing(percent: Double)      // 0.0 ... 1.0
        case done                           // caches fully populated
        case cancelled                      // shoot closed mid-flight
    }
    var indexingStatus: IndexingStatus = .idle

    /// Per-pipeline progress, surfaced by the click-through popover so the
    /// user can see which pipeline is the bottleneck. Each value is the
    /// fraction of batches that pipeline has marked `.done` (0 ... 1).
    ///
    /// Pipelines after the standard-EXIF-via-TIFF refactor:
    /// - `basicExifAndThumbs`: HEIF box parse → embedded JPEG + Exif
    ///   item bytes → TIFF parse for ExifSummary. Combined ~2 ms / file.
    /// - `advancedExif`: one-shot exiftool per batch for proprietary
    ///   Sony tags (AF, FaceN, SequenceNumber, CameraOrientation).
    ///   ~11 ms / file on a CFExpress card, dominated by card IO.
    /// - `xmpSidecars`: per-pair XMP file read. ~1 ms / file.
    struct IndexingProgress: Hashable, Sendable {
        var basicExifAndThumbs: Double = 0
        var advancedExif:       Double = 0
        var xmpSidecars:        Double = 0

        // Weights from measured wall times on a 4695-pair CFExpress
        // shoot: basic 6 s, advanced 28 s, XMP 3 s (≈37 s total).
        // 0.15 / 0.75 / 0.10 ≈ those ratios and sums to 1.0 so `total`
        // tracks the actual indexing wall-time fraction.
        static let basicExifAndThumbsWeight: Double = 0.15
        static let advancedExifWeight:       Double = 0.75
        static let xmpSidecarsWeight:        Double = 0.10

        var total: Double {
            basicExifAndThumbs * Self.basicExifAndThumbsWeight
          + advancedExif       * Self.advancedExifWeight
          + xmpSidecars        * Self.xmpSidecarsWeight
        }
    }
    var indexingProgress: IndexingProgress = .init()

    /// Per-pipeline wall-time tracking for the popover's "ETA Ns" while
    /// in flight and "took Ns" once finished. Wall time via
    /// `CFAbsoluteTimeGetCurrent` (no monotonic-clock subscription needed
    /// for second-precision UI).
    struct PipelineTiming: Hashable, Sendable {
        var startedAt:  Double?
        var finishedAt: Double?

        /// Estimated remaining seconds given current progress (0 ... 1).
        /// Returns nil for the first ~500 ms (not enough signal yet),
        /// when progress is at zero, or once the pipeline is finished.
        func eta(progress: Double, now: Double) -> TimeInterval? {
            guard let startedAt,
                  finishedAt == nil,
                  progress > 0.01,
                  progress < 1.0 else { return nil }
            let elapsed = now - startedAt
            guard elapsed > 0.5 else { return nil }
            return elapsed * (1.0 - progress) / progress
        }

        /// Total wall time of the pipeline (nil until finished).
        var duration: TimeInterval? {
            guard let startedAt, let finishedAt else { return nil }
            return finishedAt - startedAt
        }
    }

    struct PipelineTimings: Hashable, Sendable {
        var basicExifAndThumbs: PipelineTiming = .init()
        var advancedExif:       PipelineTiming = .init()
        var xmpSidecars:        PipelineTiming = .init()
    }
    var indexingTimings: PipelineTimings = .init()

    /// Wall-clock timestamp of when the whole indexing run last finished
    /// (`.done`). Used by the popover's "Indexed Xm ago" header. Reset
    /// when a new indexing run starts or a shoot is closed.
    var indexingCompletedAt: Date?

    private var indexingTask: Task<Void, Never>?
    private var batchQueues: (advancedExif: BatchQueue,
                              xmp: BatchQueue,
                              basicExif: BatchQueue)?
    /// Stem → batch id for the advanced-EXIF + XMP pipelines (50-pair
    /// batches).
    private var stemToAdvancedExifBatchID: [String: Int] = [:]
    /// Stem → batch id for the basic-EXIF + thumbs pipeline (5-pair
    /// batches). Kept separate so signal prioritisation maps to the
    /// right id per queue.
    private var stemToBasicExifBatchID: [String: Int] = [:]
    /// 50-pair batches shared by the advanced-EXIF + XMP pipelines.
    private var advancedExifBatches: [[PhotoPair]] = []
    /// 5-pair batches used by the basic-EXIF + thumbs pipeline —
    /// smaller so a navigation signal bumps a tighter slice of work to
    /// the head, keeping user-visible thumbnails appearing fast even
    /// on big shoots.
    private var basicExifBatches: [[PhotoPair]] = []

    /// Advanced-EXIF + XMP share this batch size. 50 keeps argv
    /// lengths and JSON parse cost reasonable while amortising
    /// exiftool's cold start.
    private static let advancedExifBatchSize = 50
    /// Basic-EXIF + thumbs batches stay small so concurrent loads
    /// finish quickly and signal-prioritised batches land fast.
    private static let basicExifBatchSize = 5
    /// All `basicExifBatchSize` files in a batch run in parallel inside
    /// the pipeline; the inner TaskGroup just gathers results.
    private static let basicExifConcurrency = 5
    /// Number of parallel advanced-EXIF workers. Each worker spawns
    /// one exiftool per batch, so N workers = up to N concurrent
    /// exiftool processes. 1 = serial; 2 is the measured sweet spot
    /// on a CFExpress reader; 4 helps on faster NVMe SSDs.
    private static let advancedExifWorkerCount = 2

    let pipeline: DecodePipeline = DecodePipeline()

    /// Read live from UserDefaults so changes in Settings take effect on the
    /// next rating action — no app restart required.
    private func autoAdvanceAfterRating(source: RatingInputSource) -> Bool {
        switch source {
        case .keyboard: return AppDefaults.shared.bool(forKey: SettingsKey.autoAdvance)
        case .sidebar:  return AppDefaults.shared.bool(forKey: SettingsKey.autoAdvanceSidebar)
        }
    }

    init() {
        let defaults = AppDefaults.shared
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
    /// previous single-pair flow. Kicks off indexing BEFORE the first image
    /// decode so the focus pair's metadata batch is already in flight by
    /// the time the HEIF preview lands on-screen.
    func loadShoot(_ shoot: Shoot, focus: PhotoPair) async {
        resetForShootSwitch()
        self.shoot = shoot
        self.currentIndex = shoot.index(of: focus) ?? 0
        // Skip Recents for card paths — they're either still mounted
        // (already surfaced by VolumeWatcher in the Cards section) or
        // gone (the SD/CFExpress card was pulled out and the path is
        // permanently missing). Either way no value in cluttering
        // Recents with `/Volumes/<NAME>/DCIM/<folder>` entries.
        if !Self.isCardShootPath(shoot.folderURL) {
            RecentShoots.shared.add(shoot.folderURL.path)
        }
        startIndexing()
        await applyCurrentPair(resetViewport: true)
    }

    /// True iff the URL looks like a DCIM shoot folder mounted under
    /// `/Volumes/<NAME>/DCIM/<100MSDCF-style>`. Reuses the same DCIM-
    /// name check VolumeScanner uses to populate the Cards section, so
    /// the "is this from a card?" definition stays single-sourced.
    static func isCardShootPath(_ url: URL) -> Bool {
        let comps = url.pathComponents
        guard comps.count >= 5,
              comps[1] == "Volumes",
              comps[comps.count - 2] == "DCIM",
              let leaf = comps.last,
              VolumeScanner.isDCIMConventionName(leaf)
        else { return false }
        return true
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

        // 2) Cancel the indexer; pipelines and the progress ticker observe
        //    Task.isCancelled + shootGeneration drift and unwind cleanly.
        indexingTask?.cancel()
        indexingTask = nil
        batchQueues = nil
        stemToAdvancedExifBatchID.removeAll()
        stemToBasicExifBatchID.removeAll()
        advancedExifBatches.removeAll()
        basicExifBatches.removeAll()

        // 3) Clear all caches.
        pipeline.cache.clear()
        thumbnails.removeAll()
        pairXMPs.removeAll()
        pairAFData.removeAll()
        pairSequenceNumber.removeAll()
        pairExif.removeAll()
        burstIDByStem.removeAll()
        burstSizesByID.removeAll()
        indexingStatus = .idle
        indexingProgress = .init()
        indexingTimings = .init()
        indexingCompletedAt = nil

        // 4) Reset per-pair UI state.
        currentIndex = 0
        currentImage = nil
        currentXMP = .empty
        currentExif = nil
        currentHistogram = nil
        currentAFRegions = []
        currentAFSettings = AFSettings()
        currentPairFiles = .none
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

    // MARK: - Indexer (sole loader for EXIF / AF / XMP / SequenceNumber / thumbnails)
    //
    // The shoot is sliced into 50-pair batches at start. Three independent
    // pipeline workers (exiftool, XMP, thumbnails) pull batches off their
    // own priority queue. Each pipeline guarantees a batch is processed at
    // most once. `prioritizeBatch(forStem:)` bumps a pair's batch to the
    // head of all three queues so the focus pair's data lands fast even
    // mid-indexing.

    func startIndexing() {
        guard let shoot else { return }
        let gen = shootGeneration

        advancedExifBatches = stride(from: 0, to: shoot.pairs.count, by: Self.advancedExifBatchSize).map {
            Array(shoot.pairs[$0 ..< min($0 + Self.advancedExifBatchSize, shoot.pairs.count)])
        }
        basicExifBatches = stride(from: 0, to: shoot.pairs.count, by: Self.basicExifBatchSize).map {
            Array(shoot.pairs[$0 ..< min($0 + Self.basicExifBatchSize, shoot.pairs.count)])
        }
        stemToAdvancedExifBatchID.removeAll(keepingCapacity: true)
        stemToBasicExifBatchID.removeAll(keepingCapacity: true)
        for (id, batch) in advancedExifBatches.enumerated() {
            for pair in batch { stemToAdvancedExifBatchID[pair.stem] = id }
        }
        for (id, batch) in basicExifBatches.enumerated() {
            for pair in batch { stemToBasicExifBatchID[pair.stem] = id }
        }

        let advancedExifCount = advancedExifBatches.count
        let basicExifCount    = basicExifBatches.count
        if advancedExifCount == 0 && basicExifCount == 0 {
            indexingStatus = .done
            batchQueues = nil
            return
        }
        let queues = (advancedExif: BatchQueue(batchCount: advancedExifCount),
                      xmp:          BatchQueue(batchCount: advancedExifCount),
                      basicExif:    BatchQueue(batchCount: basicExifCount))
        batchQueues = queues

        indexingStatus = .indexing(percent: 0)
        indexingProgress = .init()
        let startTime = CFAbsoluteTimeGetCurrent()
        indexingTimings = PipelineTimings(
            basicExifAndThumbs: PipelineTiming(startedAt: startTime),
            advancedExif:       PipelineTiming(startedAt: startTime),
            xmpSidecars:        PipelineTiming(startedAt: startTime)
        )
        #if DEBUG
        Log.app.notice("Indexing \(shoot.pairs.count, privacy: .public) pairs: \(advancedExifCount, privacy: .public) advanced exif/xmp batches × \(Self.advancedExifBatchSize, privacy: .public), \(basicExifCount, privacy: .public) basic exif + thumbs batches × \(Self.basicExifBatchSize, privacy: .public), \(Self.advancedExifWorkerCount, privacy: .public) advanced exif workers")
        #endif

        indexingTask = Task(priority: .utility) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                // N parallel advanced-EXIF workers, each spawning a
                // one-shot exiftool per batch. They safely share one
                // queue (BatchQueue.popNext no-double-pop is tested).
                for _ in 0 ..< Self.advancedExifWorkerCount {
                    group.addTask { [weak self] in
                        await self?.runAdvancedExifPipeline(queue: queues.advancedExif, gen: gen)
                    }
                }
                group.addTask { [weak self] in
                    await self?.runXMPPipeline(queue: queues.xmp, gen: gen)
                }
                group.addTask { [weak self] in
                    await self?.runBasicExifAndThumbsPipeline(queue: queues.basicExif, gen: gen)
                }
                group.addTask { [weak self] in
                    await self?.progressTicker(queues: queues,
                                               advancedExifBatchCount: advancedExifCount,
                                               basicExifBatchCount: basicExifCount,
                                               gen: gen)
                }
            }
            self?.finishIndexing(generation: gen)
        }

        // Make sure the pair the user is looking at gets indexed first.
        if let stem = pair?.stem {
            prioritizeBatch(forStem: stem)
        }
    }

    /// Re-run indexing from scratch. Wipes the four eager caches, bumps
    /// shootGeneration so any in-flight pipeline task observes the change
    /// and bails, and starts a fresh indexing task. The status-bar
    /// "Re-index" button is the only caller today.
    func reIndex() {
        guard shoot != nil else { return }
        indexingTask?.cancel()
        indexingTask = nil
        shootGeneration &+= 1
        thumbnails.removeAll()
        pairXMPs.removeAll()
        pairAFData.removeAll()
        pairSequenceNumber.removeAll()
        pairExif.removeAll()
        burstIDByStem.removeAll()
        burstSizesByID.removeAll()
        indexingProgress = .init()
        indexingTimings = .init()
        indexingCompletedAt = nil
        batchQueues = nil
        // advancedExifBatches + stemToAdvancedExifBatchID will be rebuilt
        // by startIndexing.
        startIndexing()
    }

    /// Signal the indexer to bump a pair's batch to the head of every
    /// pipeline. Resolves the stem to each pipeline's own batch id
    /// (advanced-EXIF + XMP use 50-pair batches, basic-EXIF + thumbs
    /// uses 5-pair). No-op if the batch is already in progress or done.
    func prioritizeBatch(forStem stem: String) {
        guard let queues = batchQueues else { return }
        let advancedID = stemToAdvancedExifBatchID[stem]
        let basicID    = stemToBasicExifBatchID[stem]
        Task {
            if let id = advancedID {
                await queues.advancedExif.prioritize(id)
                await queues.xmp.prioritize(id)
            }
            if let id = basicID { await queues.basicExif.prioritize(id) }
        }
    }

    // MARK: pipelines

    /// Advanced-EXIF pipeline: Sony AF / SequenceNumber /
    /// CameraOrientation. Reads only the proprietary tags via one-shot
    /// exiftool per batch; standard EXIF (Make/Model/Lens/exposure)
    /// comes from the basic-EXIF + thumbs pipeline via the in-process
    /// TIFF parser.
    ///
    /// Sharing one queue across N workers is safe per BatchQueue.popNext's
    /// no-double-pop invariant.
    private func runAdvancedExifPipeline(queue: BatchQueue, gen: Int) async {
        while let id = await queue.popNext() {
            if Task.isCancelled || shootGeneration != gen { return }
            let batch = advancedExifBatches[id]
            let urls = batch.map(\.heifURL)
            let (result, stats) = await MetadataBatchLoader.readInstrumented(urls)
            var afByStem:  [String: ExifToolRunner.AFData] = [:]
            var seqByStem: [String: Int] = [:]
            for pair in batch {
                if let v = result.af [pair.heifURL.path] { afByStem [pair.stem] = v }
                if let v = result.seq[pair.heifURL.path] { seqByStem[pair.stem] = v }
            }
            flushAdvancedExifBatch(af: afByStem, seq: seqByStem, generation: gen)
            logAdvancedExifBatchStats(id: id, stats: stats)
            await queue.markDone(id)
        }
    }

    /// Per-batch log: includes exiftool subprocess startup + scan time
    /// in `rt ms`. DEBUG-only.
    private nonisolated func logAdvancedExifBatchStats(id: Int,
                                                       stats: MetadataBatchLoader.Stats?) {
        #if DEBUG
        guard let s = stats else { return }
        let kb = s.bytesOut / 1024
        let perFileMS = Double(s.filesIn) > 0 ? s.spawnMS / Double(s.filesIn) : 0
        Log.app.notice("advanced exif batch \(id, privacy: .public): \(s.filesIn, privacy: .public) files, \(kb, privacy: .public) KB out, rt \(s.spawnMS, format: .fixed(precision: 1)) ms (\(perFileMS, format: .fixed(precision: 1)) ms/file), parse \(s.parseMS, format: .fixed(precision: 1)) ms")
        #endif
    }

    private func runXMPPipeline(queue: BatchQueue, gen: Int) async {
        while let id = await queue.popNext() {
            if Task.isCancelled || shootGeneration != gen { return }
            let batch = advancedExifBatches[id]
            let results = await Task.detached(priority: .utility) {
                batch.map { (stem: $0.stem, xmp: XMPSidecarReader.read(for: $0)) }
            }.value
            flushXMPSlice(results, generation: gen)
            await queue.markDone(id)
        }
    }

    /// Basic-EXIF + thumbs pipeline. One HEIF box parse per file gets
    /// us BOTH the embedded JPEG bytes (→ filmstrip thumbnail) AND the
    /// Exif item bytes (→ ExifSummary via TIFFEXIFParser). Standard
    /// EXIF for the sidebar therefore arrives without any subprocess
    /// or ImageIO call — measured ~2 ms / file on a CFExpress card.
    private func runBasicExifAndThumbsPipeline(queue: BatchQueue, gen: Int) async {
        while let id = await queue.popNext() {
            if Task.isCancelled || shootGeneration != gen { return }
            let batch = basicExifBatches[id]
            typealias Result = (stem: String,
                                image: CGImage?,
                                exif: ExifSummary?,
                                stats: ThumbnailLoader.Stats?)
            let results: [Result] = await withTaskGroup(of: Result.self,
                                                        returning: [Result].self) { group in
                for pair in batch {
                    let url = pair.heifURL
                    let stem = pair.stem
                    group.addTask {
                        let (img, exif, stats) = await Task.detached(priority: .utility) {
                            ThumbnailLoader.loadInstrumented(from: url)
                        }.value
                        return (stem, img, exif, stats)
                    }
                }
                var out: [Result] = []
                for await r in group { out.append(r) }
                return out
            }
            let thumbs: [(String, CGImage)] = results.compactMap {
                guard let img = $0.image else { return nil }
                return ($0.stem, img)
            }
            let exifs: [(String, ExifSummary)] = results.compactMap {
                guard let ex = $0.exif else { return nil }
                return ($0.stem, ex)
            }
            flushBasicExifAndThumbsBatch(thumbs: thumbs, exifs: exifs, generation: gen)
            logBasicExifAndThumbsBatchStats(id: id, results: results)
            await queue.markDone(id)
        }
    }

    /// Per-batch aggregate. With the in-process path: bytes is the
    /// JPEG + Exif item slice (~99 KB combined), read time folded into
    /// decode since each step is sub-ms. DEBUG-only.
    private nonisolated func logBasicExifAndThumbsBatchStats(
        id: Int,
        results: [(stem: String,
                   image: CGImage?,
                   exif: ExifSummary?,
                   stats: ThumbnailLoader.Stats?)]
    ) {
        #if DEBUG
        let stats = results.compactMap(\.stats)
        guard !stats.isEmpty else { return }
        let count    = stats.count
        let bytes    = stats.reduce(0) { $0 + $1.fileBytes }
        let decode   = stats.reduce(0.0) { $0 + $1.decodeMS }
        let kbAvg    = (bytes / max(count, 1)) / 1024
        let decAvg   = decode / Double(count)
        let withExif = results.filter { $0.exif != nil }.count
        Log.app.notice("basic exif batch \(id, privacy: .public): \(count, privacy: .public) files (\(withExif, privacy: .public) w/ exif), ~\(kbAvg, privacy: .public) KB avg, decode \(decAvg, format: .fixed(precision: 1)) ms avg")
        #endif
    }

    // MARK: flushes (all on MainActor)

    private func flushAdvancedExifBatch(af: [String: ExifToolRunner.AFData],
                                        seq: [String: Int],
                                        generation: Int) {
        guard shootGeneration == generation else { return }
        for (stem, v) in af   { pairAFData[stem]          = v }
        for (stem, v) in seq  { pairSequenceNumber[stem]  = v }
        // Roll the burst-id table forward so the filmstrip's bracket
        // overlay can read it as an O(1) lookup. Doing it here at the
        // flush boundary keeps the main thread responsive — the cost
        // is paid once per batch, not per SwiftUI render.
        if !seq.isEmpty { recomputeBurstIDs() }
        // If the just-arrived batch covers the currently-displayed
        // pair, refresh AF view-state so the overlay updates without
        // a navigation event.
        if let stem = pair?.stem, let v = af[stem] {
            self.currentAFRegions = v.regions
            self.currentAFSettings = v.settings
        }
    }

    private func flushXMPSlice(_ items: [(stem: String, xmp: XMPSidecar)],
                               generation: Int) {
        guard shootGeneration == generation else { return }
        for (stem, xmp) in items {
            // Don't overwrite an optimistic user rating — see Phase 4c
            // notes; in-memory wins if the user has already touched it.
            if pairXMPs[stem] == nil { pairXMPs[stem] = xmp }
        }
        if let stem = pair?.stem, let xmp = items.first(where: { $0.stem == stem })?.xmp,
           self.currentXMP == .empty {
            self.currentXMP = xmp
        }
    }

    /// Basic-EXIF + thumbs pipeline flush. Publishes BOTH the thumbnails
    /// (for the filmstrip) AND the standard EXIF (for the sidebar).
    /// The merged flush mirrors the merged input from a single HEIF
    /// box parse per file.
    private func flushBasicExifAndThumbsBatch(thumbs: [(String, CGImage)],
                                              exifs: [(String, ExifSummary)],
                                              generation: Int) {
        guard shootGeneration == generation else { return }
        for (stem, img) in thumbs { thumbnails[stem] = img }
        for (stem, ex)  in exifs  { pairExif[stem]   = ex }
        // Refresh the currently-displayed pair's sidebar EXIF if it
        // happens to be in this batch.
        if let stem = pair?.stem,
           let ex = exifs.first(where: { $0.0 == stem })?.1 {
            self.currentExif = ex
        }
    }

    // MARK: progress

    private func progressTicker(queues: (advancedExif: BatchQueue,
                                          xmp: BatchQueue,
                                          basicExif: BatchQueue),
                                advancedExifBatchCount: Int,
                                basicExifBatchCount: Int,
                                gen: Int) async {
        while !Task.isCancelled, shootGeneration == gen {
            let advancedDone = await queues.advancedExif.snapshotDoneCount()
            let xmpDone      = await queues.xmp.snapshotDoneCount()
            let basicDone    = await queues.basicExif.snapshotDoneCount()
            let p = IndexingProgress(
                basicExifAndThumbs: basicExifBatchCount    == 0 ? 1 : Double(basicDone)    / Double(basicExifBatchCount),
                advancedExif:       advancedExifBatchCount == 0 ? 1 : Double(advancedDone) / Double(advancedExifBatchCount),
                xmpSidecars:        advancedExifBatchCount == 0 ? 1 : Double(xmpDone)      / Double(advancedExifBatchCount)
            )
            let advancedDoneNow = advancedDone >= advancedExifBatchCount
            let xmpDoneNow      = xmpDone      >= advancedExifBatchCount
            let basicDoneNow    = basicDone    >= basicExifBatchCount
            setIndexingProgress(p,
                                advancedExifFinished: advancedDoneNow,
                                xmpFinished:          xmpDoneNow,
                                basicExifFinished:    basicDoneNow,
                                generation: gen)
            if advancedDoneNow, xmpDoneNow, basicDoneNow { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func setIndexingProgress(_ p: IndexingProgress,
                                     advancedExifFinished: Bool,
                                     xmpFinished: Bool,
                                     basicExifFinished: Bool,
                                     generation: Int) {
        guard shootGeneration == generation else { return }
        // Don't downgrade a terminal status.
        if case .done = indexingStatus { return }
        if case .cancelled = indexingStatus { return }
        indexingProgress = p
        indexingStatus = .indexing(percent: min(max(p.total, 0), 1))
        // Record per-pipeline completion timestamps on the transition.
        // Latches once set so subsequent ticks don't keep moving the
        // "took Ns" target.
        let now = CFAbsoluteTimeGetCurrent()
        if advancedExifFinished, indexingTimings.advancedExif.finishedAt == nil {
            indexingTimings.advancedExif.finishedAt = now
        }
        if xmpFinished, indexingTimings.xmpSidecars.finishedAt == nil {
            indexingTimings.xmpSidecars.finishedAt = now
        }
        if basicExifFinished, indexingTimings.basicExifAndThumbs.finishedAt == nil {
            indexingTimings.basicExifAndThumbs.finishedAt = now
        }
    }

    private func finishIndexing(generation: Int) {
        guard shootGeneration == generation else { return }
        indexingStatus = .done
        indexingCompletedAt = Date()

        // One production summary line per indexing run — has everything
        // needed to diagnose performance later: pair count + per-pipeline
        // wall times. The three pipelines run in parallel so the total
        // wall time is the max, not the sum.
        let pairs = shoot?.pairs.count ?? 0
        let advancedDur = indexingTimings.advancedExif.duration       ?? 0
        let xmpDur      = indexingTimings.xmpSidecars.duration        ?? 0
        let basicDur    = indexingTimings.basicExifAndThumbs.duration ?? 0
        let total = max(advancedDur, max(xmpDur, basicDur))
        Log.app.notice("Indexing complete: \(pairs, privacy: .public) pairs in \(formattedDuration(total), privacy: .public) (basic \(formattedDuration(basicDur), privacy: .public), advanced \(formattedDuration(advancedDur), privacy: .public), xmp \(formattedDuration(xmpDur), privacy: .public))")
    }

    // MARK: - Burst detection (filmstrip bracket overlay)

    /// Burst id per pair stem. Pairs whose `Sony:SequenceNumber` is one
    /// greater than the previous (name-sorted) pair's share an id. Frames
    /// without a sequence number break any in-progress run. Computed
    /// against the whole shoot — never the filtered/sorted view — so
    /// filter toggles can't break up a burst's grouping.
    ///
    /// Reading is O(1) — the cache is rebuilt by `recomputeBurstIDs()`
    /// from the indexer's exif flush boundary, so the per-frame SwiftUI
    /// render cost stays flat regardless of shoot size.
    private(set) var burstIDByStem: [String: Int] = [:]

    /// Total membership per burst id across the FULL shoot. Used to drop
    /// singleton bursts (size 1) regardless of the current filter.
    private(set) var burstSizesByID: [Int: Int] = [:]

    /// Recompute `burstIDByStem` + `burstSizesByID` from the current
    /// `pairSequenceNumber` cache + name-sorted pair list. Called by the
    /// indexer whenever an exif batch lands new SequenceNumber data, and
    /// by tests that seed `pairSequenceNumber` directly. O(N over the
    /// shoot); safe to call on MainActor.
    func recomputeBurstIDs() {
        guard let shoot else {
            burstIDByStem = [:]
            burstSizesByID = [:]
            return
        }
        var ids: [String: Int] = [:]
        var nextID = 0
        var prevSeq: Int? = nil
        for pair in shoot.pairs {
            guard let seq = pairSequenceNumber[pair.stem] else {
                prevSeq = nil
                continue
            }
            if let prev = prevSeq, seq == prev + 1 {
                ids[pair.stem] = nextID
            } else {
                nextID += 1
                ids[pair.stem] = nextID
            }
            prevSeq = seq
        }
        var sizes: [Int: Int] = [:]
        for id in ids.values { sizes[id, default: 0] += 1 }
        burstIDByStem = ids
        burstSizesByID = sizes
    }

    /// Where this pair sits in its burst, expressed as a top-edge bracket
    /// segment for the filmstrip. The shape depends on whether the
    /// immediate visible neighbours share its burst id — so a burst stays
    /// visually grouped even when filters hide some of its frames.
    enum BurstSegment: Sendable, Hashable {
        case none      // no bracket here
        case start     // left cap + bar to the right edge
        case middle    // bar across the full width
        case end       // bar from the left edge + right cap
    }

    /// Pure helper. `visible` is the filmstrip's display-order list (after
    /// sort + filter). Returns `.none` unless sort == .name AND the pair
    /// belongs to a multi-frame burst AND at least one VISIBLE neighbour
    /// shares its burst id.
    ///
    /// This convenience overload rebuilds the burst id + size dicts on
    /// every call, which is O(N) over the shoot. **Do not call this in a
    /// per-cell render loop** — use `Self.burstSegment(at:in:ids:sizes:)`
    /// with hoisted ids/sizes so the cost stays O(visible) per render
    /// instead of O(visible × N).
    func burstSegment(at index: Int, visible: [PhotoPair]) -> BurstSegment {
        guard sortMode == .name else { return .none }
        return Self.burstSegment(at: index, in: visible,
                                 ids: burstIDByStem,
                                 sizes: burstSizesByID)
    }

    /// Per-cell segment helper that takes pre-hoisted burst id + size
    /// dicts. Caller (FilmstripView) reads `burstIDByStem` / `burstSizesByID`
    /// ONCE at the top of its body and passes them through so this loop
    /// stays O(1) per cell.
    static func burstSegment(at index: Int, in visible: [PhotoPair],
                             ids: [String: Int],
                             sizes: [Int: Int]) -> BurstSegment {
        guard visible.indices.contains(index) else { return .none }
        guard let myID = ids[visible[index].stem],
              (sizes[myID] ?? 0) >= 2 else { return .none }

        func sharesBurst(_ otherIdx: Int) -> Bool {
            guard visible.indices.contains(otherIdx) else { return false }
            return ids[visible[otherIdx].stem] == myID
        }
        let leftMatches  = sharesBurst(index - 1)
        let rightMatches = sharesBurst(index + 1)
        switch (leftMatches, rightMatches) {
        case (false, false): return .none      // lone visible burst member
        case (false, true):  return .start
        case (true,  true):  return .middle
        case (true,  false): return .end
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
                #if DEBUG
                Log.app.notice("XMP write OK: \(capturedPair.stem, privacy: .public) rating=\(rating.map(String.init) ?? "nil", privacy: .public)")
                #endif
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
                #if DEBUG
                Log.app.notice("XMP label write OK: \(capturedPair.stem, privacy: .public) label=\(label ?? "nil", privacy: .public)")
                #endif
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
            #if DEBUG
            Log.app.notice("auto-swap: HEIF → RAW (pz \(prev, format: .fixed(precision: 2)) → \(curr, format: .fixed(precision: 2)))")
            #endif
            requestedVariant = .raw
            await applyRequestedVariant()
        }
    }

    /// Apply everything for the current pair. Metadata (EXIF, AF, XMP,
    /// thumbnails, SequenceNumber) comes from the indexer's caches — this
    /// method does NOT spawn any metadata Task. If the cache is cold for
    /// the pair, the view shows empty/placeholder state and we signal the
    /// indexer to bump that batch to the head of every pipeline; the flush
    /// methods will fill `currentXxx` when the batch lands.
    private func applyCurrentPair(resetViewport: Bool) async {
        guard let pair else { return }
        PerfTracker.mark("applyCurrentPair entered")
        // Keep currentImage as-is so the previous frame stays on screen until
        // the new one decodes — avoids a flash to ProgressView (which would
        // tear down the ImageCanvasView and lose SwiftUI focus).
        self.errorMessage = nil
        self.displayedVariant = .heif
        self.requestedVariant = .heif
        if resetViewport {
            self.viewport = .identity
            self.currentPixelZoom = 1.0
        }
        let af = pairAFData[pair.stem]
        self.currentExif        = pairExif[pair.stem]
        self.currentAFRegions   = af?.regions ?? []
        self.currentAFSettings  = af?.settings ?? AFSettings()
        self.currentXMP         = pairXMPs[pair.stem] ?? .empty
        self.currentPairFiles   = pairFiles(for: pair)
        prioritizeBatch(forStem: pair.stem)
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

    /// Warm the HEIF decode cache for index ±1 so arrow-key navigation
    /// renders the next image without waiting. Image decode is its own
    /// pipeline — the indexer does not own it.
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
        }
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
