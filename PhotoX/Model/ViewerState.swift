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
    struct IndexingProgress: Hashable, Sendable {
        var exif:  Double = 0
        var xmp:   Double = 0
        var thumb: Double = 0
        /// Mean of the three. The status-bar chip displays this; the
        /// popover shows the breakdown.
        var total: Double { (exif + xmp + thumb) / 3 }
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
        var exif:  PipelineTiming = .init()
        var xmp:   PipelineTiming = .init()
        var thumb: PipelineTiming = .init()
    }
    var indexingTimings: PipelineTimings = .init()

    private var indexingTask: Task<Void, Never>?
    private var batchQueues: (exif: BatchQueue, xmp: BatchQueue, thumb: BatchQueue)?
    /// Stem → batch id for the exif + xmp pipelines (50-pair batches).
    private var stemToBatchID: [String: Int] = [:]
    /// Stem → batch id for the thumbnail pipeline (5-pair batches). Kept
    /// separate so signal prioritisation maps to the right id per queue.
    private var stemToThumbBatchID: [String: Int] = [:]
    /// 50-pair batches shared by exif + xmp pipelines.
    private var pairBatches: [[PhotoPair]] = []
    /// 5-pair batches used by the thumbnail pipeline — smaller so a
    /// navigation signal bumps a tighter slice of work to the head, which
    /// keeps user-visible thumbnails appearing fast even on big shoots.
    private var thumbBatches: [[PhotoPair]] = []

    /// Exif + XMP share this batch size. Smaller batches mean more
    /// exiftool cold-starts, which dominate, so this stays at 50.
    private static let exifBatchSize = 50
    /// Thumbnails get a much smaller batch so concurrent loads finish
    /// quickly and signal-prioritised batches land fast.
    private static let thumbBatchSize = 10
    /// All `thumbBatchSize` thumbnails in a batch load in parallel; with
    /// `thumbBatchSize == thumbConcurrency` the batch completes in roughly
    /// the time of its slowest single load.
    private static let thumbConcurrency = 10

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
        RecentShoots.shared.add(shoot.folderURL.path)
        startIndexing()
        await applyCurrentPair(resetViewport: true)
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
        stemToBatchID.removeAll()
        stemToThumbBatchID.removeAll()
        pairBatches.removeAll()
        thumbBatches.removeAll()

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

        pairBatches = stride(from: 0, to: shoot.pairs.count, by: Self.exifBatchSize).map {
            Array(shoot.pairs[$0 ..< min($0 + Self.exifBatchSize, shoot.pairs.count)])
        }
        thumbBatches = stride(from: 0, to: shoot.pairs.count, by: Self.thumbBatchSize).map {
            Array(shoot.pairs[$0 ..< min($0 + Self.thumbBatchSize, shoot.pairs.count)])
        }
        stemToBatchID.removeAll(keepingCapacity: true)
        stemToThumbBatchID.removeAll(keepingCapacity: true)
        for (id, batch) in pairBatches.enumerated() {
            for pair in batch { stemToBatchID[pair.stem] = id }
        }
        for (id, batch) in thumbBatches.enumerated() {
            for pair in batch { stemToThumbBatchID[pair.stem] = id }
        }

        let exifCount  = pairBatches.count
        let thumbCount = thumbBatches.count
        if exifCount == 0 && thumbCount == 0 {
            indexingStatus = .done
            batchQueues = nil
            return
        }
        let queues = (exif:  BatchQueue(batchCount: exifCount),
                      xmp:   BatchQueue(batchCount: exifCount),
                      thumb: BatchQueue(batchCount: thumbCount))
        batchQueues = queues

        indexingStatus = .indexing(percent: 0)
        indexingProgress = .init()
        let startTime = CFAbsoluteTimeGetCurrent()
        indexingTimings = PipelineTimings(
            exif:  PipelineTiming(startedAt: startTime),
            xmp:   PipelineTiming(startedAt: startTime),
            thumb: PipelineTiming(startedAt: startTime)
        )
        Log.app.notice("Indexing \(shoot.pairs.count, privacy: .public) pairs: \(exifCount, privacy: .public) exif/xmp batches × \(Self.exifBatchSize, privacy: .public), \(thumbCount, privacy: .public) thumb batches × \(Self.thumbBatchSize, privacy: .public)")

        indexingTask = Task(priority: .utility) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await self?.runExifPipeline(queue: queues.exif, gen: gen)
                }
                group.addTask { [weak self] in
                    await self?.runXMPPipeline(queue: queues.xmp, gen: gen)
                }
                group.addTask { [weak self] in
                    await self?.runThumbPipeline(queue: queues.thumb, gen: gen)
                }
                group.addTask { [weak self] in
                    await self?.progressTicker(queues: queues,
                                               exifBatchCount: exifCount,
                                               thumbBatchCount: thumbCount,
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
        batchQueues = nil
        // pairBatches + stemToBatchID will be rebuilt by startIndexing.
        startIndexing()
    }

    /// Signal the indexer to bump a pair's batch to the head of every
    /// pipeline. Resolves the stem to each pipeline's own batch id
    /// (exif/xmp use 50-pair batches, thumbnails use 5-pair batches).
    /// No-op if the batch is already in progress or done.
    func prioritizeBatch(forStem stem: String) {
        guard let queues = batchQueues else { return }
        let exifID  = stemToBatchID[stem]
        let thumbID = stemToThumbBatchID[stem]
        Task {
            if let id = exifID {
                await queues.exif.prioritize(id)
                await queues.xmp.prioritize(id)
            }
            if let id = thumbID { await queues.thumb.prioritize(id) }
        }
    }

    // MARK: pipelines

    private func runExifPipeline(queue: BatchQueue, gen: Int) async {
        while let id = await queue.popNext() {
            if Task.isCancelled || shootGeneration != gen { return }
            let batch = pairBatches[id]
            let urls = batch.map(\.rawURL)
            let (result, stats) = await Task.detached(priority: .utility) {
                MetadataBatchLoader.readInstrumented(urls)
            }.value
            var afByStem:   [String: ExifToolRunner.AFData] = [:]
            var exifByStem: [String: ExifSummary] = [:]
            var seqByStem:  [String: Int] = [:]
            for pair in batch {
                if let v = result.af  [pair.rawURL.path] { afByStem  [pair.stem] = v }
                if let v = result.exif[pair.rawURL.path] { exifByStem[pair.stem] = v }
                if let v = result.seq [pair.rawURL.path] { seqByStem [pair.stem] = v }
            }
            flushExifBatch(af: afByStem, exif: exifByStem, seq: seqByStem,
                           generation: gen)
            logExifBatchStats(id: id, stats: stats)
            await queue.markDone(id)
        }
    }

    /// Per-batch breakdown of exiftool subprocess time vs in-process JSON
    /// parse time. Lets us tell whether exiftool is slow (per-file scan or
    /// spawn cold-start) or our Swift parsing is the bottleneck.
    private nonisolated func logExifBatchStats(id: Int,
                                                stats: MetadataBatchLoader.Stats?) {
        guard let s = stats else { return }
        let kb = s.bytesOut / 1024
        let perFileMS = Double(s.filesIn) > 0 ? s.spawnMS / Double(s.filesIn) : 0
        Log.app.notice("exif batch \(id, privacy: .public): \(s.filesIn, privacy: .public) files, \(kb, privacy: .public) KB out, spawn \(s.spawnMS, format: .fixed(precision: 1)) ms (\(perFileMS, format: .fixed(precision: 1)) ms/file), parse \(s.parseMS, format: .fixed(precision: 1)) ms")
    }

    private func runXMPPipeline(queue: BatchQueue, gen: Int) async {
        while let id = await queue.popNext() {
            if Task.isCancelled || shootGeneration != gen { return }
            let batch = pairBatches[id]
            let results = await Task.detached(priority: .utility) {
                batch.map { (stem: $0.stem, xmp: XMPSidecarReader.read(for: $0)) }
            }.value
            flushXMPSlice(results, generation: gen)
            await queue.markDone(id)
        }
    }

    private func runThumbPipeline(queue: BatchQueue, gen: Int) async {
        while let id = await queue.popNext() {
            if Task.isCancelled || shootGeneration != gen { return }
            let batch = thumbBatches[id]
            // With thumbBatchSize == thumbConcurrency every pair in the
            // batch loads in parallel; the inner TaskGroup just gathers
            // results. ImageIO is thread-safe; HEIF embedded-thumb reads
            // are independent.
            typealias Result = (stem: String, image: CGImage?, stats: ThumbnailLoader.Stats?)
            let results: [Result] = await withTaskGroup(of: Result.self,
                                                        returning: [Result].self) { group in
                for pair in batch {
                    let url = pair.heifURL
                    let stem = pair.stem
                    group.addTask {
                        let (img, stats) = await Task.detached(priority: .utility) {
                            ThumbnailLoader.loadInstrumented(from: url)
                        }.value
                        return (stem, img, stats)
                    }
                }
                var out: [Result] = []
                for await r in group { out.append(r) }
                return out
            }
            let loaded: [(String, CGImage)] = results.compactMap {
                guard let img = $0.image else { return nil }
                return ($0.stem, img)
            }
            flushThumbBatch(loaded, generation: gen)
            logThumbBatchStats(id: id, results: results)
            await queue.markDone(id)
        }
    }

    /// Per-batch aggregate of file-read vs decode timings. Surface in
    /// Console.app via `subsystem == "dev.frostman.PhotoX"` filter — gives
    /// us a quick answer to "is the bottleneck disk or CPU" on any given
    /// shoot without needing a profiler attached.
    private nonisolated func logThumbBatchStats(
        id: Int,
        results: [(stem: String, image: CGImage?, stats: ThumbnailLoader.Stats?)]
    ) {
        let stats = results.compactMap(\.stats)
        guard !stats.isEmpty else { return }
        let count    = stats.count
        let bytes    = stats.reduce(0) { $0 + $1.fileBytes }
        let read     = stats.reduce(0.0) { $0 + $1.readMS }
        let decode   = stats.reduce(0.0) { $0 + $1.decodeMS }
        let kbAvg    = (bytes / max(count, 1)) / 1024
        let readAvg  = read / Double(count)
        let decAvg   = decode / Double(count)
        Log.app.notice("thumb batch \(id, privacy: .public): \(count, privacy: .public) files, ~\(kbAvg, privacy: .public) KB avg, read \(readAvg, format: .fixed(precision: 1)) ms avg, decode \(decAvg, format: .fixed(precision: 1)) ms avg")
    }

    // MARK: flushes (all on MainActor)

    private func flushExifBatch(af: [String: ExifToolRunner.AFData],
                                exif: [String: ExifSummary],
                                seq: [String: Int],
                                generation: Int) {
        guard shootGeneration == generation else { return }
        for (stem, v) in af   { pairAFData[stem]          = v }
        for (stem, v) in exif { pairExif[stem]            = v }
        for (stem, v) in seq  { pairSequenceNumber[stem]  = v }
        // Roll the burst-id table forward so the filmstrip's bracket
        // overlay can read it as an O(1) lookup. Doing it here at the
        // flush boundary (~60 times per 3 k-pair shoot, instead of per
        // SwiftUI render which could be thousands of times) is the perf
        // contract that keeps the main thread responsive during indexing.
        if !seq.isEmpty { recomputeBurstIDs() }
        // If the just-arrived batch covers the currently-displayed pair,
        // refresh the view-state fields so the sidebar / AF overlay update
        // without waiting for a navigation event.
        if let stem = pair?.stem {
            if let v = exif[stem] { self.currentExif = v }
            if let v = af[stem] {
                self.currentAFRegions = v.regions
                self.currentAFSettings = v.settings
            }
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

    private func flushThumbBatch(_ items: [(String, CGImage)], generation: Int) {
        guard shootGeneration == generation else { return }
        for (stem, img) in items { thumbnails[stem] = img }
    }

    // MARK: progress

    private func progressTicker(queues: (exif: BatchQueue, xmp: BatchQueue, thumb: BatchQueue),
                                exifBatchCount: Int,
                                thumbBatchCount: Int,
                                gen: Int) async {
        while !Task.isCancelled, shootGeneration == gen {
            let exifDone  = await queues.exif.snapshotDoneCount()
            let xmpDone   = await queues.xmp.snapshotDoneCount()
            let thumbDone = await queues.thumb.snapshotDoneCount()
            let p = IndexingProgress(
                exif:  exifBatchCount  == 0 ? 1 : Double(exifDone)  / Double(exifBatchCount),
                xmp:   exifBatchCount  == 0 ? 1 : Double(xmpDone)   / Double(exifBatchCount),
                thumb: thumbBatchCount == 0 ? 1 : Double(thumbDone) / Double(thumbBatchCount)
            )
            let exifDoneNow  = exifDone  >= exifBatchCount
            let xmpDoneNow   = xmpDone   >= exifBatchCount
            let thumbDoneNow = thumbDone >= thumbBatchCount
            setIndexingProgress(p,
                                exifFinished:  exifDoneNow,
                                xmpFinished:   xmpDoneNow,
                                thumbFinished: thumbDoneNow,
                                generation: gen)
            if exifDoneNow, xmpDoneNow, thumbDoneNow { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func setIndexingProgress(_ p: IndexingProgress,
                                     exifFinished: Bool,
                                     xmpFinished: Bool,
                                     thumbFinished: Bool,
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
        if exifFinished, indexingTimings.exif.finishedAt == nil {
            indexingTimings.exif.finishedAt = now
        }
        if xmpFinished, indexingTimings.xmp.finishedAt == nil {
            indexingTimings.xmp.finishedAt = now
        }
        if thumbFinished, indexingTimings.thumb.finishedAt == nil {
            indexingTimings.thumb.finishedAt = now
        }
    }

    private func finishIndexing(generation: Int) {
        guard shootGeneration == generation else { return }
        indexingStatus = .done
        Log.app.notice("Indexing complete")
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
        self.perfStats.afMS     = (af != nil) ? 0 : nil
        self.perfStats.afCached = af != nil
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
