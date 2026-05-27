import Observation
import SwiftUI

/// Where a rating/label/reject action originated from. Each source has its
/// own auto-advance setting so power-users can opt into shortcut-only
/// auto-advance while keeping sidebar clicks deliberate (or vice-versa).
enum RatingInputSource {
    case keyboard
    case sidebar
}

/// Order in which entries appear in the filmstrip + navigation. Filmstrip is
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

    var entry: PhotoEntry? {
        let entries = sortedEntries
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    var decoder: DecoderChoice = .imageIO

    var displayedVariant: ImageVariant = .preview
    var requestedVariant: ImageVariant = .preview
    var autoSwapEnabled: Bool

    var overlays: OverlayToggles = .init()
    var sidebarVisible: Bool

    var viewport: CanvasViewport = .identity
    var currentImage: DecodedImage?
    /// The `DecodeKey` corresponding to `currentImage`. Updated
    /// atomically with `currentImage` in `applyRequestedVariant` so
    /// the canvas can look up the matching texture in MTLTextureCache.
    /// Nil iff `currentImage` is nil.
    var currentImageKey: DecodeKey?
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
    var entryAFData: [String: ExifToolRunner.AFData] = [:]

    var currentXMP: XMPSidecar = .empty
    private var xmpGeneration: Int = 0

    /// What's *actually on screen* right now — used by the filmstrip,
    /// AF overlay, sidebar EXIF, and "N/M" indicator so they stay in
    /// sync with the bound texture during rapid navigation. Lags
    /// behind `currentIndex` by the duration of the async texture
    /// upload (typically 40–250 ms warm). `commitDisplayed(stem:)` is
    /// called from the canvas when a texture lands and bumps these
    /// fields atomically.
    var displayedIndex: Int = 0
    var displayedExif: ExifSummary?
    var displayedAFRegions: [AFRegion] = []
    var displayedAFSettings: AFSettings = AFSettings()
    var displayedXMP: XMPSidecar = .empty
    /// Display-orientation pixel size of the image currently bound to
    /// the canvas. AF overlay reads this — using `currentImage.pixelSize`
    /// would race during a portrait→landscape transition (AF rects are
    /// for the still-bound portrait, but `currentImage` is already the
    /// landscape texture-in-flight, causing one frame of mis-scaled
    /// rects). Updated atomically with the other displayed* fields.
    var displayedPixelSize: CGSize = .zero

    /// Pair that's currently rendered on the canvas — derived from
    /// `displayedIndex`. Differs from `entry` (derived from `currentIndex`)
    /// only briefly while a navigation's texture is still loading.
    var displayedEntry: PhotoEntry? {
        let entries = sortedEntries
        guard entries.indices.contains(displayedIndex) else { return nil }
        return entries[displayedIndex]
    }

    /// True when the user has navigated to a entry whose texture isn't
    /// yet on screen — drives the centred loading indicator over the
    /// canvas and the "block rating/reject during nav lag" guard.
    /// Two cases:
    /// 1. **Navigation in flight**: the navigation-intent entry (`entry`)
    ///    differs from the displayed entry — the new texture is being
    ///    decoded + uploaded.
    /// 2. **First-frame load**: `currentImage` is still nil because
    ///    the initial decode hasn't completed yet.
    /// Returns false when no shoot is loaded (nothing to load).
    var isLoadingDisplayedPair: Bool {
        guard let currentStem = entry?.stem else { return false }
        if currentImage == nil { return true }
        return currentStem != displayedEntry?.stem
    }

    /// Bumped on every shoot teardown (closeShoot, loadShoot). Any background
    /// task that might write into per-shoot state (thumbnails, entryXMPs,
    /// entryAFData) captures this at spawn time and checks it before applying
    /// its result. This drops stale writes from tasks that finish after the
    /// user closed the shoot or switched folders.
    private var shootGeneration: Int = 0

    var currentEntryFiles: EntryFiles = .none

    struct EntryFiles: Hashable, Sendable {
        var arw: Bool = false
        var hif: Bool = false
        var jpg: Bool = false
        var xmp: Bool = false
        static let none = EntryFiles()
    }

    // Filmstrip
    var filmstripVisible: Bool

    /// Sort order for the filmstrip + navigation. Session-only (not persisted).
    /// Mutating this through `setSortMode(_:)` preserves the currently-focused
    /// entry across the reorder. Direct assignment (e.g. via a Picker binding)
    /// does NOT remap currentIndex — always go through setSortMode.
    private(set) var sortMode: SortMode = .name

    /// `shoot.entries` re-ordered per `sortMode`. Cached; invalidated on
    /// shoot switch, sort-mode change, and any rating mutation that can
    /// change ordering. `.name` mode is O(1) anyway; score modes were
    /// O(N log N) per access (~5–10× per nav press → a latent cliff in
    /// score-sort modes that the cache erases).
    var sortedEntries: [PhotoEntry] {
        if let cached = sortedEntriesCache { return cached }
        guard let shoot else { return [] }
        let computed: [PhotoEntry]
        switch sortMode {
        case .name:
            computed = shoot.entries
        case .scoreAscending:
            computed = shoot.entries.sorted { a, b in
                let sa = sortScore(of: a)
                let sb = sortScore(of: b)
                if sa != sb { return sa < sb }
                return a.stem < b.stem
            }
        case .scoreDescending:
            computed = shoot.entries.sorted { a, b in
                let sa = sortScore(of: a)
                let sb = sortScore(of: b)
                if sa != sb { return sa > sb }
                return a.stem < b.stem
            }
        }
        sortedEntriesCache = computed
        return computed
    }

    private var sortedEntriesCache: [PhotoEntry]?

    private func invalidateSortedEntriesCache() {
        sortedEntriesCache = nil
        // The filmstrip's visible/collapse/bracket result derives from
        // sortedEntries × filters × burst tables — anything that
        // invalidates the sort necessarily invalidates this too.
        invalidateFilmstripVisibleCache()
    }

    // MARK: - Filmstrip visible cache
    //
    // Hoist the filmstrip body's per-nav work (filter pass + collapse
    // pass + bracket precompute) onto the state so plain nav inside
    // the same burst is a single dict lookup. On a 25k mixed-burst
    // shoot the per-nav cost drops from ~15 ms to <1 ms.
    //
    // The cache key folds in everything the result actually depends on
    // (filter toggles, sort mode, collapse mode, expanded-burst id) so
    // a user-visible state change automatically misses the cache and
    // recomputes. Internal data-change events (rating mutations,
    // burst-id rebuilds) bump `filmstripDataVersion` instead — keyed
    // separately because they don't have a clean external signal.

    struct FilmstripVisible: Sendable {
        let allVisible: [(offset: Int, element: PhotoEntry)]
        let visible: [(offset: Int, element: PhotoEntry)]
        let firstByBurst: [Int: Int]
        let lastByBurst: [Int: Int]
    }

    private struct FilmstripVisibleKey: Equatable {
        let sortMode: SortMode
        let showRejected: Bool
        let showUnrated: Bool
        let showStars: Set<Int>
        let collapseActive: Bool
        let expandedBurstID: Int?
        let dataVersion: Int
    }

    private var filmstripVisibleCacheKey: FilmstripVisibleKey?
    private var filmstripVisibleCache: FilmstripVisible?
    private var filmstripDataVersion: Int = 0
    /// Test-only counter — incremented every time the cache actually
    /// recomputes (cache miss path). Tests assert it stays flat across
    /// expected cache-hit operations and bumps on expected misses.
    /// Visible to tests via `@testable import PhotoX`.
    private(set) var filmstripVisibleComputesForTests: Int = 0

    private func invalidateFilmstripVisibleCache() {
        filmstripDataVersion &+= 1
        filmstripVisibleCache = nil
        filmstripVisibleCacheKey = nil
    }

    /// Cached compute of the filmstrip's visible/collapse/bracket
    /// tables. All inputs are derived from `self` so the key always
    /// matches what the compute will actually see — there's no way
    /// to ask for "the result if showRejected were X" without first
    /// flipping `state.showRejected` to X.
    ///
    /// `collapseActive` is the one exception: it folds the
    /// `@AppStorage(SettingsKey.collapseBursts)` value (owned by
    /// FilmstripView) with `!isIndexingActive` (owned by state). The
    /// caller is responsible for that combination.
    func filmstripVisible(collapseActive: Bool) -> FilmstripVisible {
        // Expanded burst is nil when the focused entry is a singleton
        // (or has no burst id yet) — singletons aren't subject to
        // collapse, so the visible result is identical regardless of
        // which one the user is currently on. This keeps the key
        // stable while nav'ing through the standalone half of the
        // shoot — 12 k+ keys' worth of cache hits.
        let expandedBurstID: Int? = {
            guard let stem = displayedEntry?.stem,
                  let id = burstIDByStem[stem],
                  (burstSizesByID[id] ?? 0) >= 2 else { return nil }
            return id
        }()
        let key = FilmstripVisibleKey(
            sortMode: sortMode,
            showRejected: showRejected,
            showUnrated: showUnrated,
            showStars: showStars,
            collapseActive: collapseActive,
            expandedBurstID: expandedBurstID,
            dataVersion: filmstripDataVersion
        )
        if let cached = filmstripVisibleCache, filmstripVisibleCacheKey == key {
            return cached
        }
        let computed = computeFilmstripVisible(
            collapseActive: collapseActive,
            expandedBurstID: expandedBurstID
        )
        filmstripVisibleCache = computed
        filmstripVisibleCacheKey = key
        return computed
    }

    private func computeFilmstripVisible(
        collapseActive: Bool,
        expandedBurstID: Int?
    ) -> FilmstripVisible {
        filmstripVisibleComputesForTests &+= 1
        let allVisible: [(offset: Int, element: PhotoEntry)] = sortedEntries
            .enumerated()
            .filter { isVisible($1) }
            .map { (offset: $0.offset, element: $0.element) }
        let useBrackets = sortMode == .name
        let enumeratedVisible: [(offset: Int, element: PhotoEntry)] = {
            guard collapseActive, useBrackets else { return allVisible }
            var seen: Set<Int> = []
            return allVisible.filter { _, entry in
                guard let id = burstIDByStem[entry.stem],
                      (burstSizesByID[id] ?? 0) >= 2
                else { return true }                  // singleton
                if id == expandedBurstID { return true } // expanded
                return seen.insert(id).inserted       // 1st of burst
            }
        }()
        var firstByBurst: [Int: Int] = [:]
        var lastByBurst: [Int: Int] = [:]
        if useBrackets {
            for (vIdx, pair) in enumeratedVisible.enumerated() {
                guard let id = burstIDByStem[pair.element.stem],
                      (burstSizesByID[id] ?? 0) >= 2 else { continue }
                if firstByBurst[id] == nil { firstByBurst[id] = vIdx }
                lastByBurst[id] = vIdx
            }
        }
        return FilmstripVisible(
            allVisible: allVisible,
            visible: enumeratedVisible,
            firstByBurst: firstByBurst,
            lastByBurst: lastByBurst
        )
    }

    /// Numeric score for sort comparisons. Rejected (-1) sinks below unrated
    /// (0) in asc mode and stays at the bottom in desc mode by sort symmetry.
    private func sortScore(of entry: PhotoEntry) -> Int {
        entryXMPs[entry.stem]?.rating ?? 0
    }

    /// Change the sort mode while preserving which entry is currently focused.
    /// Use this instead of writing to `sortMode` directly — otherwise the
    /// entry under `currentIndex` will shift to whatever entry happens to land
    /// at that index in the new order.
    func setSortMode(_ newMode: SortMode) {
        guard newMode != sortMode else { return }
        let currentStem = entry?.stem
        sortMode = newMode
        invalidateSortedEntriesCache()
        invalidateShootStatsCache()
        if let stem = currentStem,
           let idx = sortedEntries.firstIndex(where: { $0.stem == stem }) {
            currentIndex = idx
        }
    }

    // Filters (session-only — not persisted). On = category is included
    // in the filmstrip + navigation. didSet hooks invalidate the
    // filmstrip-visible cache so flipping a filter recomputes on the
    // next read instead of returning stale results.
    var showRejected: Bool = true {
        didSet { if oldValue != showRejected { invalidateFilmstripVisibleCache() } }
    }
    var showUnrated: Bool = true {
        didSet { if oldValue != showUnrated { invalidateFilmstripVisibleCache() } }
    }
    /// Which star ratings (1...5) to include. Default: all. Toggling individual
    /// stars off in the status bar replaces the previous single "Rated" flag.
    var showStars: Set<Int> = [1, 2, 3, 4, 5] {
        didSet { if oldValue != showStars { invalidateFilmstripVisibleCache() } }
    }

    enum RatingCategory: Sendable, Hashable {
        case rejected
        case rated(stars: Int)   // 1...5
        case unrated
    }

    func ratingCategory(for stem: String) -> RatingCategory {
        let xmp = entryXMPs[stem] ?? .empty
        if xmp.isReject { return .rejected }
        if let stars = xmp.starCount, stars > 0 { return .rated(stars: stars) }
        return .unrated
    }

    func isVisible(_ entry: PhotoEntry) -> Bool {
        switch ratingCategory(for: entry.stem) {
        case .rejected:           return showRejected
        case .rated(let stars):   return showStars.contains(stars)
        case .unrated:            return showUnrated
        }
    }

    /// Counts across the entire shoot. Cached; invalidated on shoot switch
    /// and on every rating mutation. The status bar reads this on every
    /// render and the indexer flushes ~5×/sec — without the cache the
    /// O(N over shoot) recompute crowded the main thread during indexing
    /// (~70 ms/sec on an 8k-entry shoot). `stars[i]` (i = 1...5) holds
    /// the per-star count; `rated` is the sum.
    typealias ShootStats = (rated: Int, rejected: Int, unrated: Int, stars: [Int: Int], total: Int)

    var shootStats: ShootStats {
        if let cached = shootStatsCache { return cached }
        guard let shoot else { return (0, 0, 0, [:], 0) }
        var rated = 0, rejected = 0, unrated = 0
        var stars: [Int: Int] = [:]
        for entry in shoot.entries {
            switch ratingCategory(for: entry.stem) {
            case .rated(let n):
                rated += 1
                stars[n, default: 0] += 1
            case .rejected:
                rejected += 1
            case .unrated:
                unrated += 1
            }
        }
        let computed: ShootStats = (rated, rejected, unrated, stars, shoot.entries.count)
        shootStatsCache = computed
        return computed
    }

    private var shootStatsCache: ShootStats?

    private func invalidateShootStatsCache() {
        shootStatsCache = nil
    }

    /// How many entries the user is currently looking at (= sum of enabled
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
    // per-entry lazy fetches anywhere. `applyCurrentEntry` reads them
    // synchronously; SwiftUI re-renders when the flush methods publish a
    // batch's results to the cache.

    var thumbnails: [String: CGImage] = [:]
    var entryXMPs: [String: XMPSidecar] = [:]
    /// Stems whose `.xmp` sidecar exists on disk. Populated by the
    /// XMP indexer pipeline as it scans (the reader returns nil for
    /// missing files), and by the rating/label/reject mutators when
    /// a successful write creates the sidecar. Read by `entryFiles`
    /// for the per-nav files-badge so we don't have to `stat()` the
    /// sidecar on every arrow press. Cleared on shoot switch.
    private(set) var stemsWithXMPOnDisk: Set<String> = []
    /// Sony `SequenceNumber` per entry stem; filter-independent (every loaded
    /// entry has its raw number). Drives `burstIDByStem` for the filmstrip
    /// bracket overlay.
    var entrySequenceNumber: [String: Int] = [:]
    /// EXIF summary for the sidebar, indexed eagerly via the exiftool batch
    /// loader. Replaces the per-navigation ImageIO read.
    var entryExif: [String: ExifSummary] = [:]

    /// Per-shoot cache of computed histograms, keyed by entry stem.
    /// A `Histogram` is small (~3 KB: 256 bins × 3 channels × 4 B);
    /// even a 5 000-entry shoot is ~15 MB — no need to cap. Cleared in
    /// `resetForShootSwitch`. Eliminates the histogram-recompute
    /// spike on revisit (texture cache hit is now matched by
    /// histogram cache hit — sidebar updates instantly).
    var entryHistograms: [String: Histogram] = [:]

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
    /// - `xmpSidecars`: per-entry XMP file read. ~1 ms / file.
    struct IndexingProgress: Hashable, Sendable {
        var basicExifAndThumbs: Double = 0
        var advancedExif:       Double = 0
        var xmpSidecars:        Double = 0

        // Weights from measured wall times on a 4695-entry CFExpress
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
    /// Per-neighbour prefetch tasks (warm decode + texture upload),
    /// keyed by entry stem. Cancelled when the stem leaves the
    /// neighbour set OR on shoot switch.
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    /// The task spawned by the most recent `navigate(to:)` — running
    /// `applyCurrentEntry` → `applyRequestedVariant`. Cancelled by the
    /// next navigate so intermediate decode results never reach the
    /// canvas during a fast arrow burst.
    private var currentApplyTask: Task<Void, Never>?
    private var batchQueues: (advancedExif: BatchQueue,
                              xmp: BatchQueue,
                              basicExif: BatchQueue)?
    /// Stem → batch id for the advanced-EXIF + XMP pipelines (50-entry
    /// batches).
    private var stemToAdvancedExifBatchID: [String: Int] = [:]
    /// Stem → batch id for the basic-EXIF + thumbs pipeline (5-entry
    /// batches). Kept separate so signal prioritisation maps to the
    /// right id per queue.
    private var stemToBasicExifBatchID: [String: Int] = [:]
    /// 50-entry batches shared by the advanced-EXIF + XMP pipelines.
    private var advancedExifBatches: [[PhotoEntry]] = []
    /// 5-entry batches used by the basic-EXIF + thumbs pipeline —
    /// smaller so a navigation signal bumps a tighter slice of work to
    /// the head, keeping user-visible thumbnails appearing fast even
    /// on big shoots.
    private var basicExifBatches: [[PhotoEntry]] = []

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

    /// All XMP sidecar writes route through this actor — per-stem
    /// serialization + retry (100 ms / 500 ms backoff) + a failure
    /// stream that surfaces to the UI via `failedXMPWrites` and the
    /// titlebar pill. **Never** write to XMP directly from this
    /// class or from any other call site; see project memory
    /// `project_xmp_write_reliability.md`.
    let xmpWriter = XMPWriteCoordinator()

    /// Lifetime usage counters surfaced in the Stats window and (when
    /// the user opts in) uploaded to PostHog. Mutators tick in-memory
    /// only; a background task persists every
    /// `TelemetryConfig.localPersistInterval`. Counters live across
    /// shoots / app launches — never cleared by `resetForShootSwitch`.
    let metrics = UsageMetrics()

    /// On-disk indexer cache scoped to the currently-open shoot.
    /// Recreated by `loadShoot` for each new shoot. Pipelines check
    /// `cache.entry(for:sourceURL:)` first; on hit they skip their
    /// pipeline work and stuff the cached data into the in-memory
    /// maps. On miss they run as before and call `cache.updateEntry`
    /// on flush to capture the result for next time.
    private(set) var cache: IndexerCache = IndexerCache(
        shootFolder: URL(fileURLWithPath: "/"))

    /// PostHog upload client. API key comes from Info.plist
    /// (`POSTHOG_API_KEY`); empty in dev builds without an injected
    /// key — `flush` short-circuits as a no-op. Periodic flush task
    /// kicked off in `init` reads `telemetryEnabled` from
    /// UserDefaults at each tick, so toggling the setting takes
    /// effect on the next 6-hour boundary without restart.
    let telemetryUploader: TelemetryUploader = {
        let key = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY")
            as? String ?? ""
        return TelemetryUploader(apiKey: key)
    }()

    /// Long-lived periodic telemetry-flush task. Always running;
    /// each tick gates on `settings.telemetryEnabled`. Toggle-on
    /// from Settings → Privacy also calls `uploadTelemetryNow()`
    /// directly so the user sees an event in PostHog right away.
    private var telemetryPeriodicTask: Task<Void, Never>?

    /// Standard Cocoa undo stack for rating / label / reject
    /// mutations. Cleared on shoot switch (cross-shoot undo makes
    /// no sense). The SwiftUI menu items in PhotoXApp call
    /// `.undo()` / `.redo()` on this directly.
    ///
    /// Capped at 500 top-level groups so a 10-20k-image culling
    /// session can't accumulate an unbounded snapshot history —
    /// each registered undo captures a whole XMPSidecar plus a
    /// few small fields, ~a couple-hundred bytes; 500 entries
    /// stays well under 1 MB. At ~1-2 actions/sec that's still
    /// 5-10 minutes of work the user can walk back.
    let undoManager: UndoManager = {
        let m = UndoManager()
        m.levelsOfUndo = 500
        return m
    }()

    /// Observable counter bumped whenever the undo manager's
    /// state changes (group close, undo, redo, action-name
    /// change). The CommandGroup that builds Edit → Undo / Redo
    /// reads this so SwiftUI knows to re-evaluate `canUndo` /
    /// `canRedo` / `undoMenuItemTitle` — UndoManager itself isn't
    /// `@Observable`, so without this signal the menu items'
    /// enabled state and titles would never refresh.
    private(set) var undoStateVersion: Int = 0
    private var undoObservers: [NSObjectProtocol] = []

    /// Last failed XMP write per stem (older failures for the same
    /// file are overwritten — we only care about the most recent
    /// state). Populated by the failure-consumer Task started in
    /// `init`. Read by `FailedWritesView` (sorted by stem). When
    /// non-empty, the red titlebar pill becomes visible.
    var failedXMPWrites: [String: XMPWriteCoordinator.FailedWrite] = [:]

    private var xmpFailureConsumerTask: Task<Void, Never>?

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
        startXMPFailureConsumer()
        startUndoStateObserver()
        // Wire ExportRunner's per-destination completion event into
        // UsageMetrics. Set after `metrics` is initialised — a
        // captured weak self avoids the runner clinging to us if
        // ViewerState is ever re-init'd (tests).
        ExportRunner.shared.onDestinationCompleted = { [weak self] summary in
            self?.metrics.recordExportCompleted(imageCount: summary.copied)
        }
        startTelemetryPeriodicLoop()
    }

    // MARK: - Telemetry

    /// Snapshot the current totals (after a forced metrics persist) and
    /// upload to PostHog. Called from the Settings → Privacy toggle on
    /// the way ON, and from `startTelemetryPeriodicLoop`.
    /// Returns immediately if telemetry is disabled or no API key
    /// is present in the bundle.
    func uploadTelemetryNow() async {
        let enabled = AppDefaults.shared.bool(forKey: SettingsKey.telemetryEnabled)
        guard enabled else { return }
        await metrics.flushPending()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
        // GitDescribe is injected by release.sh / `just dev` (see
        // project.yml's Info.plist properties). Falls back to
        // appVersion when missing so PostHog never sees an empty
        // string for app_describe.
        let appDescribe = Bundle.main.object(forInfoDictionaryKey: "GitDescribe")
            as? String ?? appVersion
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let result = await telemetryUploader.flush(
            counters: metrics.total,
            firstLaunchAt: metrics.firstLaunchAt,
            appVersion: appVersion,
            appDescribe: appDescribe,
            osVersion: osVersion
        )
        if result.success {
            metrics.markUploaded(at: Date())
            Log.app.notice("telemetry: flush ok (status=\(result.httpStatus ?? -1, privacy: .public))")
        } else {
            Log.app.warning("telemetry: flush failed: \(result.error ?? "unknown", privacy: .public)")
        }
    }

    /// Periodic background flush. Awakens every
    /// `TelemetryConfig.uploadInterval`, checks the toggle, uploads
    /// if enabled. Always running for the lifetime of the
    /// ViewerState — no need to start / stop with the toggle since
    /// `uploadTelemetryNow` gates internally and is cheap when
    /// disabled.
    private func startTelemetryPeriodicLoop() {
        telemetryPeriodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: TelemetryConfig.uploadInterval)
                if Task.isCancelled { return }
                await self?.uploadTelemetryNow()
            }
        }
    }

    /// Watch UndoManager for state changes and bump the observable
    /// `undoStateVersion`. NSUndoManager posts these notifications
    /// on its own actor (the main one for our manager) but adding
    /// the observers explicitly on the main queue keeps the
    /// version bump on @MainActor.
    ///
    /// CRITICAL: do NOT observe `NSUndoManagerCheckpoint`. Per
    /// Apple docs that notification posts on every `canRedo`
    /// query — and SwiftUI's menu rebuild reads `canRedo`. The
    /// resulting feedback loop (render → query canRedo →
    /// checkpoint → undoStateVersion bump → render → ...) pegged
    /// the CPU at ~95 % on idle whenever a second window (e.g.
    /// Stats) sat in the responder chain and triggered menu
    /// validations. Subscribe only to mutation notifications.
    /// `resetForShootSwitch`'s explicit `removeAllActions`
    /// produces no notification, so it bumps undoStateVersion
    /// directly.
    private func startUndoStateObserver() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
        ]
        for name in names {
            let token = nc.addObserver(
                forName: name,
                object: undoManager,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.undoStateVersion &+= 1 }
            }
            undoObservers.append(token)
        }
    }

    /// Pump every event from `xmpWriter.failureStream` onto the
    /// main actor and into `failedXMPWrites`. Started once at init
    /// and runs for the lifetime of the ViewerState — never
    /// cancelled. (Even after shoot switch we want to surface any
    /// late-arriving failures for the previous shoot's writes.)
    private func startXMPFailureConsumer() {
        let stream = xmpWriter.failureStream
        xmpFailureConsumerTask = Task { @MainActor [weak self] in
            for await failure in stream {
                guard let self else { return }
                // Last write per stem wins — older failures for the
                // same file get overwritten, so the list shows the
                // current state per file, not a history.
                self.failedXMPWrites[failure.stem] = failure
                Log.app.error("XMP write FAILED after \(failure.attempts, privacy: .public) attempts: \(failure.stem, privacy: .public) \(failure.kind.description, privacy: .public) — \(failure.lastError, privacy: .public)")
            }
        }
    }

    /// Re-enqueue every currently-failed write. The dict is cleared
    /// pre-emptively; anything that fails again will repopulate it
    /// via the failure stream. Called by the failures-window
    /// "Retry All" button.
    func retryAllFailedXMPWrites() {
        let snapshot = failedXMPWrites
        failedXMPWrites.removeAll()
        guard let shoot else { return }
        for (stem, failed) in snapshot {
            guard let entry = shoot.entries.first(where: { $0.stem == stem }) else { continue }
            // Re-derive the intended value from the current in-memory
            // state — that's what the user wanted; failed.kind is
            // what the original (now-superseded) write was trying.
            let current = entryXMPs[stem] ?? .empty
            switch failed.kind {
            case .rating: Task { await xmpWriter.writeRating(current.rating, for: entry) }
            case .label:  Task { await xmpWriter.writeLabel(current.label,  for: entry) }
            }
        }
    }


    /// Loads a shoot and focuses on a specific entry within it. Replaces the
    /// previous single-entry flow. Kicks off indexing BEFORE the first image
    /// decode so the focus entry's metadata batch is already in flight by
    /// the time the HEIF preview lands on-screen.
    func loadShoot(_ shoot: Shoot, focus: PhotoEntry) async {
        // Before we tear down the current shoot, save the user's
        // last position so a future reopen (favorite / recent click,
        // app relaunch) lands them back where they were.
        captureLastEntryToStores()
        // Persist the previous shoot's indexer cache before tearing
        // down. Best-effort — quit-time hook is a backstop.
        let oldCache = cache
        Task { await oldCache.close() }
        resetForShootSwitch()
        metrics.recordShootOpened()
        // Swap in a cache scoped to the new shoot. Reading the
        // existing .plist (if any) happens synchronously in the
        // initializer — typically <100 ms even for 20 k entries.
        cache = IndexerCache(shootFolder: shoot.folderURL)
        // Every shoot opens with collapse-bursts off — the indexer
        // hasn't started yet and the burst table will only be
        // complete once indexing finishes (the StatusBarView button
        // is disabled until then). The @AppStorage-backed views
        // observe this UserDefaults write and re-render.
        AppDefaults.shared.set(false, forKey: SettingsKey.collapseBursts)
        self.shoot = shoot
        self.currentIndex = shoot.index(of: focus) ?? 0
        // displayedIndex mirrors currentIndex on shoot load — the first
        // texture upload will fire commitDisplayed and keep it in sync
        // from there.
        self.displayedIndex = self.currentIndex
        // Skip Recents for card paths — they're either still mounted
        // (already surfaced by VolumeWatcher in the Cards section) or
        // gone (the SD/CFExpress card was pulled out and the path is
        // permanently missing). Either way no value in cluttering
        // Recents with `/Volumes/<NAME>/DCIM/<folder>` entries.
        if !Self.isCardShootPath(shoot.folderURL) {
            RecentShoots.shared.add(shoot.folderURL.path)
        }
        startIndexing()
        await applyCurrentEntry(resetViewport: true)
    }

    /// Save the user's current position to both the recents and
    /// favorites stores. Idempotent (the stores no-op when the
    /// path isn't in their list). Called on shoot-switch (inside
    /// `loadShoot`) and on app-background (from `PhotoXApp`'s
    /// scenePhase handler). Card shoots are skipped to match the
    /// recents-skip policy: their paths aren't in either store.
    func captureLastEntryToStores() {
        guard let shoot, let stem = displayedEntry?.stem else { return }
        let path = shoot.folderURL.path
        if Self.isCardShootPath(shoot.folderURL) { return }
        RecentShoots.shared.setLastEntry(stem, for: path)
        FavoriteShoots.shared.setLastEntry(stem, for: path)
    }

    /// True iff the URL looks like a DCIM shoot folder mounted under
    /// `/Volumes/<NAME>/DCIM/<100MSDCF-style>` AND the underlying
    /// volume is a locally-mounted removable device (i.e. an actual
    /// SD / CFExpress card or USB reader).
    ///
    /// Path-shape alone isn't enough — NAS shares (SMB / AFP / NFS)
    /// that happen to mirror the DCIM folder structure (a common
    /// backup pattern) match the path heuristic but the user
    /// definitely wants them in Recents. Combining the path check
    /// with `volumeIsLocal && volumeIsRemovable` distinguishes
    /// "card in a reader" from "network archive of a card."
    static func isCardShootPath(_ url: URL) -> Bool {
        let comps = url.pathComponents
        guard comps.count >= 5,
              comps[1] == "Volumes",
              comps[comps.count - 2] == "DCIM",
              let leaf = comps.last,
              VolumeScanner.isDCIMConventionName(leaf)
        else { return false }
        let vals = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeIsRemovableKey,
        ])
        let isLocal = vals?.volumeIsLocal ?? false
        let isRemovable = vals?.volumeIsRemovable ?? false
        return isLocal && isRemovable
    }

    /// E2E-test only: rewind every user-visible piece of state to
    /// a freshly-launched baseline so the shared-session XCUITest
    /// suite can run consecutive tests without an app restart.
    /// `closeShoot()` covers the shoot + filter/sort/undo reset
    /// already; the extras here are the toggles and surfaces that
    /// individual tests are allowed to mutate. NEVER call in
    /// production — there's no UI surface for it and the
    /// `failedXMPWrites` wipe would silently swallow real errors.
    func resetForUITest() {
        closeShoot()
        // Failed XMP writes deliberately persist across shoots in
        // production (the user must see them). For tests we want
        // a clean slate so the titlebar pill doesn't leak.
        failedXMPWrites.removeAll()
        // Toggles the existing E2E suite mutates (B, T, X, A).
        sidebarVisible    = SettingsKey.Defaults.sidebarVisible
        filmstripVisible  = SettingsKey.Defaults.filmstripVisible
        autoSwapEnabled   = SettingsKey.Defaults.autoSwapToRAW
        overlays          = .init()
        requestedVariant  = .preview
    }

    /// Drop the current shoot and return to the empty starter state.
    func closeShoot() {
        // Save the user's position before tearing down so reopening
        // this shoot (favorite / recent click) lands on the same entry.
        captureLastEntryToStores()
        // Final flush of the indexer cache. Detached so the cleanup
        // doesn't block the UI; cache.close handles its own
        // background encode.
        let oldCache = cache
        Task { await oldCache.close() }
        resetForShootSwitch()
        shoot = nil
        // Replace with a no-op cache so subsequent calls don't
        // touch the previous shoot's data.
        cache = IndexerCache(shootFolder: URL(fileURLWithPath: "/"))
        // Reset session-only filter + sort to defaults so the next
        // shoot opens with a clean slate instead of inheriting the
        // last shoot's culling state (which usually wasn't relevant).
        showStars = [1, 2, 3, 4, 5]
        showRejected = true
        showUnrated = true
        sortMode = .name
        // Wipe export pill/sheet progress so the starter screen is
        // clean — the runner itself guards against clearing while
        // an export is still running.
        ExportRunner.shared.resetState()
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

        // 3) Cancel any in-flight neighbour prefetches and the current
        // apply-task, then clear all caches. DecodedImage no longer
        // cached (texture cache replaced it); clear the texture cache
        // + the HIF byte cache so shoots don't leak memory across
        // switches.
        currentApplyTask?.cancel()
        currentApplyTask = nil
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
        MTLTextureCache.shared.clear()
        Task { await pipeline.previewBytes.clear() }
        thumbnails.removeAll()
        entryXMPs.removeAll()
        stemsWithXMPOnDisk.removeAll()
        entryAFData.removeAll()
        entrySequenceNumber.removeAll()
        entryExif.removeAll()
        entryHistograms.removeAll()
        burstIDByStem.removeAll()
        burstSizesByID.removeAll()
        burstPositionByStem.removeAll()
        sortedEntriesCache = nil
        shootStatsCache = nil
        filmstripVisibleCache = nil
        filmstripVisibleCacheKey = nil
        // Cross-shoot undo would be confusing (you'd be undoing
        // ratings on a shoot that's no longer open) and the
        // captured PhotoEntry references would dangle anyway.
        undoManager.removeAllActions()
        // removeAllActions doesn't post DidUndoChange / DidRedoChange
        // / DidCloseUndoGroup, so the observer wouldn't see it. Bump
        // manually so the menu items re-render to disabled.
        undoStateVersion &+= 1
        indexingStatus = .idle
        indexingProgress = .init()
        indexingTimings = .init()
        indexingCompletedAt = nil

        // 4) Reset per-entry UI state.
        currentIndex = 0
        currentImage = nil
        currentImageKey = nil
        currentXMP = .empty
        currentExif = nil
        currentHistogram = nil
        currentAFRegions = []
        currentAFSettings = AFSettings()
        currentEntryFiles = .none
        displayedIndex = 0
        displayedExif = nil
        displayedAFRegions = []
        displayedAFSettings = AFSettings()
        displayedXMP = .empty
        displayedPixelSize = .zero
        errorMessage = nil
        isDecoding = false
        viewport = .identity
        currentPixelZoom = 1.0
        displayedVariant = .preview
        requestedVariant = .preview
    }

    func toggleFilmstrip() {
        filmstripVisible.toggle()
    }

    // MARK: - Indexer (sole loader for EXIF / AF / XMP / SequenceNumber / thumbnails)
    //
    // The shoot is sliced into 50-entry batches at start. Three independent
    // pipeline workers (exiftool, XMP, thumbnails) pull batches off their
    // own priority queue. Each pipeline guarantees a batch is processed at
    // most once. `prioritizeBatch(forStem:)` bumps a entry's batch to the
    // head of all three queues so the focus entry's data lands fast even
    // mid-indexing.

    func startIndexing() {
        guard let shoot else { return }
        let gen = shootGeneration

        advancedExifBatches = stride(from: 0, to: shoot.entries.count, by: Self.advancedExifBatchSize).map {
            Array(shoot.entries[$0 ..< min($0 + Self.advancedExifBatchSize, shoot.entries.count)])
        }
        basicExifBatches = stride(from: 0, to: shoot.entries.count, by: Self.basicExifBatchSize).map {
            Array(shoot.entries[$0 ..< min($0 + Self.basicExifBatchSize, shoot.entries.count)])
        }
        stemToAdvancedExifBatchID.removeAll(keepingCapacity: true)
        stemToBasicExifBatchID.removeAll(keepingCapacity: true)
        for (id, batch) in advancedExifBatches.enumerated() {
            for entry in batch { stemToAdvancedExifBatchID[entry.stem] = id }
        }
        for (id, batch) in basicExifBatches.enumerated() {
            for entry in batch { stemToBasicExifBatchID[entry.stem] = id }
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
        Log.app.notice("Indexing \(shoot.entries.count, privacy: .public) entries: \(advancedExifCount, privacy: .public) advanced exif/xmp batches × \(Self.advancedExifBatchSize, privacy: .public), \(basicExifCount, privacy: .public) basic exif + thumbs batches × \(Self.basicExifBatchSize, privacy: .public), \(Self.advancedExifWorkerCount, privacy: .public) advanced exif workers")
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

        // Make sure the entry the user is looking at gets indexed first.
        if let stem = entry?.stem {
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
        entryXMPs.removeAll()
        stemsWithXMPOnDisk.removeAll()
        entryAFData.removeAll()
        entrySequenceNumber.removeAll()
        entryExif.removeAll()
        burstIDByStem.removeAll()
        burstSizesByID.removeAll()
        burstPositionByStem.removeAll()
        sortedEntriesCache = nil
        shootStatsCache = nil
        indexingProgress = .init()
        indexingTimings = .init()
        indexingCompletedAt = nil
        batchQueues = nil
        // advancedExifBatches + stemToAdvancedExifBatchID will be rebuilt
        // by startIndexing.
        startIndexing()
    }

    /// Signal the indexer to bump a entry's batch to the head of every
    /// pipeline. Resolves the stem to each pipeline's own batch id
    /// (advanced-EXIF + XMP use 50-entry batches, basic-EXIF + thumbs
    /// uses 5-entry). No-op if the batch is already in progress or done.
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
            // Cache hit fast-path: entries whose previewURL hasn't
            // changed since the last cache flush get served from
            // the cache; only the misses go through exiftool. For
            // a fully-cached re-open this skips the whole
            // subprocess spawn for the batch.
            //
            // stat() each entry ONCE here — the fingerprint we
            // compute drives BOTH the cache lookup AND the
            // subsequent cache.updateEntry on a miss.
            var afFromCache:  [String: ExifToolRunner.AFData] = [:]
            var seqFromCache: [String: Int] = [:]
            var misses: [(entry: PhotoEntry, fingerprint: IndexerCache.Fingerprint?)] = []
            for entry in batch {
                let fp = try? IndexerCache.fingerprint(of: entry.previewURL)
                if let fp,
                   let hit = cache.entry(for: entry.stem, fingerprint: fp) {
                    if let af  = hit.afData          { afFromCache[entry.stem]  = af }
                    if let seq = hit.sequenceNumber  { seqFromCache[entry.stem] = seq }
                    // If neither field is in the cache for this
                    // entry, treat it as a miss so the pipeline
                    // populates them.
                    if hit.afData != nil || hit.sequenceNumber != nil {
                        continue
                    }
                }
                misses.append((entry, fp))
            }

            var afByStem  = afFromCache
            var seqByStem = seqFromCache
            if !misses.isEmpty {
                let urls = misses.map(\.entry.previewURL)
                let (result, stats) = await MetadataBatchLoader.readInstrumented(urls)
                for (entry, fp) in misses {
                    let af  = result.af [entry.previewURL.path]
                    let seq = result.seq[entry.previewURL.path]
                    if let af  { afByStem [entry.stem] = af }
                    if let seq { seqByStem[entry.stem] = seq }
                    // Cache whatever we learned — even partial
                    // entries (AF only / seq only) round-trip.
                    if (af != nil || seq != nil), let fp {
                        cache.updateEntry(stem: entry.stem,
                                           fingerprint: fp,
                                           afData: af,
                                           sequenceNumber: seq)
                    }
                }
                logAdvancedExifBatchStats(id: id, stats: stats)
            }
            flushAdvancedExifBatch(af: afByStem, seq: seqByStem, generation: gen)
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
            typealias Result = (entry: PhotoEntry,
                                image: CGImage?,
                                exif: ExifSummary?,
                                jpegBytes: Data?,
                                exifOrientation: Int?,
                                stats: ThumbnailLoader.Stats?)

            // Cache hit fast-path: for entries with cached JPEG
            // bytes + EXIF AND a matching file fingerprint, decode
            // the cached thumbnail (no HEIF box parse, no fresh
            // file read). Cache misses or partial cache entries
            // (missing thumb bytes / EXIF) fall through to the
            // existing pipeline.
            //
            // stat() each entry ONCE here — the fingerprint we
            // compute drives BOTH the cache lookup AND the
            // subsequent cache.updateEntry on a miss. Entries
            // whose source file is missing get a nil fingerprint
            // and skip caching entirely.
            var cachedResults: [Result] = []
            var misses: [(entry: PhotoEntry, fingerprint: IndexerCache.Fingerprint?)] = []
            for entry in batch {
                let fp = try? IndexerCache.fingerprint(of: entry.previewURL)
                if let fp,
                   let hit = cache.entry(for: entry.stem, fingerprint: fp),
                   let bytes = hit.thumbnailJPEG,
                   let exif = hit.exif {
                    // EXIF orientation (tag 0x0112) applies to both
                    // the full image AND the embedded thumbnail —
                    // they're rotated together by the camera. Use
                    // the parsed value with a fallback of 1
                    // (identity) for files that didn't store one.
                    let orientation = exif.orientation ?? 1
                    if let img = ThumbnailLoader.loadFromJPEGBytes(
                        bytes, exifOrientation: orientation)
                    {
                        cachedResults.append((entry, img, exif,
                                              bytes, orientation, nil))
                        continue
                    }
                }
                misses.append((entry, fp))
            }

            let pipelineResults: [Result] = await withTaskGroup(of: Result.self,
                                                                returning: [Result].self) { group in
                for (entry, _) in misses {
                    let url = entry.previewURL
                    group.addTask {
                        let r = await Task.detached(priority: .utility) {
                            ThumbnailLoader.loadInstrumented(from: url)
                        }.value
                        return (entry, r.image, r.exif,
                                r.jpegBytes, r.exifOrientation, r.stats)
                    }
                }
                var out: [Result] = []
                for await r in group { out.append(r) }
                return out
            }
            let results = cachedResults + pipelineResults
            let thumbs: [(String, CGImage)] = results.compactMap {
                guard let img = $0.image else { return nil }
                return ($0.entry.stem, img)
            }
            let exifs: [(String, ExifSummary)] = results.compactMap {
                guard let ex = $0.exif else { return nil }
                return ($0.entry.stem, ex)
            }
            // Capture per-entry thumbnail bytes for the on-disk
            // indexer cache. Only entries we actually got both
            // exif + thumb bytes from get cached. Reuse the
            // fingerprint we computed during the miss-detection
            // pass above — no extra stat() here.
            let missFingerprints = Dictionary(uniqueKeysWithValues:
                misses.compactMap { miss in
                    miss.fingerprint.map { fp in (miss.entry.stem, fp) }
                })
            for r in pipelineResults {
                if let ex = r.exif, let bytes = r.jpegBytes,
                   let fp = missFingerprints[r.entry.stem] {
                    cache.updateEntry(
                        stem: r.entry.stem,
                        fingerprint: fp,
                        exif: ex,
                        thumbnailJPEG: bytes
                    )
                }
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
        results: [(entry: PhotoEntry,
                   image: CGImage?,
                   exif: ExifSummary?,
                   jpegBytes: Data?,
                   exifOrientation: Int?,
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
        for (stem, v) in af   { entryAFData[stem]          = v }
        for (stem, v) in seq  { entrySequenceNumber[stem]  = v }
        // Roll the burst-id table forward so the filmstrip's bracket
        // overlay can read it as an O(1) lookup. Doing it here at the
        // flush boundary keeps the main thread responsive — the cost
        // is paid once per batch, not per SwiftUI render.
        if !seq.isEmpty { recomputeBurstIDs() }
        // If the just-arrived batch covers the currently-navigated
        // entry, refresh the canvas-overlay state. Same update for the
        // displayed entry (matches the AF overlay the user actually
        // sees) — different entry during rapid nav, often the same.
        if let stem = entry?.stem, let v = af[stem] {
            self.currentAFRegions = v.regions
            self.currentAFSettings = v.settings
        }
        if let stem = displayedEntry?.stem, let v = af[stem] {
            self.displayedAFRegions = v.regions
            self.displayedAFSettings = v.settings
        }
    }

    private func flushXMPSlice(_ items: [(stem: String, xmp: XMPSidecar?)],
                               generation: Int) {
        guard shootGeneration == generation else { return }
        var stagedAny = false
        for (stem, xmp) in items {
            guard let xmp else { continue }  // file missing → leave entryXMPs untouched
            // File present on disk — record for the per-nav files badge.
            stemsWithXMPOnDisk.insert(stem)
            // Don't overwrite an optimistic user rating — see Phase 4c
            // notes; in-memory wins if the user has already touched it.
            if entryXMPs[stem] == nil {
                entryXMPs[stem] = xmp
                if xmp.hasDecision { stagedAny = true }
            }
        }
        // Counts depend on per-entry ratings; the cache snapshotted the
        // pre-indexing all-unrated state, so invalidate it whenever a
        // batch lands actual decisions. Score-sort ordering can also
        // shift, so drop the sorted-entries cache for the same reason.
        if stagedAny {
            invalidateShootStatsCache()
            invalidateSortedEntriesCache()
        }
        if let stem = entry?.stem,
           let xmp = items.first(where: { $0.stem == stem })?.xmp ?? nil,
           self.currentXMP == .empty {
            self.currentXMP = xmp
        }
        if let stem = displayedEntry?.stem,
           let xmp = items.first(where: { $0.stem == stem })?.xmp ?? nil,
           self.displayedXMP == .empty {
            self.displayedXMP = xmp
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
        for (stem, ex)  in exifs  { entryExif[stem]   = ex }
        // Refresh the navigated entry's sidebar EXIF if it landed in
        // this batch. Mirror for the displayed entry (lags during
        // rapid nav — the sidebar reads displayedExif).
        if let stem = entry?.stem,
           let ex = exifs.first(where: { $0.0 == stem })?.1 {
            self.currentExif = ex
        }
        if let stem = displayedEntry?.stem,
           let ex = exifs.first(where: { $0.0 == stem })?.1 {
            self.displayedExif = ex
        }
    }

    /// Called by the canvas when a texture for `stem` has been bound
    /// and the new pixels are now visible. Atomically commits the
    /// filmstrip-selection / AF-overlay / sidebar-EXIF state so they
    /// match what the user actually sees. Drops the call if the stem
    /// no longer maps to any entry in the current shoot (rare race
    /// with shoot teardown). `pixelSize` is the bound texture's
    /// display dimensions — feeds the AF overlay so rects stay
    /// correctly scaled across portrait↔landscape transitions.
    func commitDisplayed(stem: String, pixelSize: CGSize) {
        PerfTracker.mark("commitDisplayed entered (stem=\(stem))")
        let entries = sortedEntries
        guard let idx = entries.firstIndex(where: { $0.stem == stem }) else {
            // Stem isn't in the current sorted view — typically a filter
            // toggle (rejects/unrated/star levels) hid the entry while
            // its texture was still loading. Clear the displayed* fields
            // so the AF overlay / sidebar / loading indicator don't
            // mis-attribute to a now-hidden entry. Clamp displayedIndex
            // into range so the filmstrip doesn't try to highlight an
            // out-of-bounds slot.
            if !entries.indices.contains(displayedIndex) {
                displayedIndex = max(0, min(displayedIndex, entries.count - 1))
            }
            displayedExif = nil
            displayedAFRegions = []
            displayedAFSettings = AFSettings()
            displayedXMP = .empty
            displayedPixelSize = .zero
            return
        }
        displayedIndex = idx
        displayedExif = entryExif[stem]
        let af = entryAFData[stem]
        displayedAFRegions = af?.regions ?? []
        displayedAFSettings = af?.settings ?? AFSettings()
        displayedXMP = entryXMPs[stem] ?? .empty
        displayedPixelSize = pixelSize
        metrics.recordPhotoSeen()
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
        // Drop cache rows for files that have been removed from
        // the shoot since the last open (~10 KB / dead file
        // otherwise). The full set of stems currently in the
        // shoot is the source of truth.
        let liveStems = Set(shoot?.entries.map(\.stem) ?? [])
        cache.pruneToStems(liveStems)
        // Persist the indexer cache once indexing has fully
        // settled. cache.flush is a no-op when nothing changed
        // since the last flush; on a cold open with a fully
        // empty cache it writes everything we just learned.
        let snapshotCache = cache
        Task { await snapshotCache.flush() }

        // One production summary line per indexing run — has everything
        // needed to diagnose performance later: entry count + per-pipeline
        // wall times. The three pipelines run in parallel so the total
        // wall time is the max, not the sum.
        let entries = shoot?.entries.count ?? 0
        let advancedDur = indexingTimings.advancedExif.duration       ?? 0
        let xmpDur      = indexingTimings.xmpSidecars.duration        ?? 0
        let basicDur    = indexingTimings.basicExifAndThumbs.duration ?? 0
        let total = max(advancedDur, max(xmpDur, basicDur))
        Log.app.notice("Indexing complete: \(entries, privacy: .public) entries in \(formattedDuration(total), privacy: .public) (basic \(formattedDuration(basicDur), privacy: .public), advanced \(formattedDuration(advancedDur), privacy: .public), xmp \(formattedDuration(xmpDur), privacy: .public))")
    }

    // MARK: - Burst detection (filmstrip bracket overlay)

    /// Burst id per entry stem. Pairs whose `Sony:SequenceNumber` is one
    /// greater than the previous (name-sorted) entry's share an id. Frames
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

    /// Per-stem 1-based position within its burst (e.g. "3 of 5"). Rebuilt
    /// alongside `burstIDByStem` so the canvas stem pill's burst label
    /// reads O(1) instead of doing a per-render `firstIndex(where:)` over
    /// the full shoot. Nil for singletons / non-burst entries.
    private(set) var burstPositionByStem: [String: (index: Int, total: Int)] = [:]

    /// Recompute `burstIDByStem` + `burstSizesByID` from the current
    /// `entrySequenceNumber` cache + name-sorted entry list. Called by the
    /// indexer whenever an exif batch lands new SequenceNumber data, and
    /// by tests that seed `entrySequenceNumber` directly. O(N over the
    /// shoot); safe to call on MainActor.
    func recomputeBurstIDs() {
        guard let shoot else {
            burstIDByStem = [:]
            burstSizesByID = [:]
            burstPositionByStem = [:]
            return
        }
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        var ids: [String: Int] = [:]
        var nextID = 0
        var prevSeq: Int? = nil
        for entry in shoot.entries {
            guard let seq = entrySequenceNumber[entry.stem] else {
                prevSeq = nil
                continue
            }
            if let prev = prevSeq, seq == prev + 1 {
                ids[entry.stem] = nextID
            } else {
                nextID += 1
                ids[entry.stem] = nextID
            }
            prevSeq = seq
        }
        var sizes: [Int: Int] = [:]
        for id in ids.values { sizes[id, default: 0] += 1 }
        // Per-burst 1-based position. Bursts are contiguous in
        // shoot.entries (name-order), so a single forward walk produces
        // (index, total) for every member in O(N) — replaces a per-render
        // firstIndex(where:) over the full shoot for each stem pill.
        var positions: [String: (index: Int, total: Int)] = [:]
        var posCursor: [Int: Int] = [:]
        for entry in shoot.entries {
            guard let id = ids[entry.stem],
                  let total = sizes[id], total >= 2 else { continue }
            let next = (posCursor[id] ?? 0) + 1
            posCursor[id] = next
            positions[entry.stem] = (next, total)
        }
        burstIDByStem = ids
        burstSizesByID = sizes
        burstPositionByStem = positions
        // Burst membership feeds the filmstrip's collapse + bracket
        // logic; any rebuild of these tables must invalidate the
        // filmstrip-visible cache or the strip would render against
        // stale burst ids.
        invalidateFilmstripVisibleCache()
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        Log.app.notice("recomputeBurstIDs: \(shoot.entries.count, privacy: .public) entries, \(ids.count, privacy: .public) burst stems, \(sizes.count, privacy: .public) bursts in \(ms, format: .fixed(precision: 1)) ms")
        #endif
    }

    /// Where this entry sits in its burst, expressed as a top-edge bracket
    /// segment for the filmstrip. The shape depends on whether the
    /// immediate visible neighbours share its burst id — so a burst stays
    /// visually grouped even when filters hide some of its frames.
    enum BurstSegment: Sendable, Hashable {
        case none      // no bracket here
        case start     // left cap + bar to the right edge
        case middle    // bar across the full width
        case end       // bar from the left edge + right cap
        case solo      // both caps + short centered bar — the only
                       // visible member of its burst (its siblings
                       // are filtered out); still part of a burst
                       // per `burstSizesByID`, just isolated in the
                       // current view.
    }

    /// Pure helper. `visible` is the filmstrip's display-order list (after
    /// sort + filter). Returns `.none` unless sort == .name AND the entry
    /// belongs to a multi-frame burst AND at least one VISIBLE neighbour
    /// shares its burst id.
    ///
    /// This convenience overload rebuilds the burst id + size dicts on
    /// every call, which is O(N) over the shoot. **Do not call this in a
    /// per-cell render loop** — use `Self.burstSegment(at:in:ids:sizes:)`
    /// with hoisted ids/sizes so the cost stays O(visible) per render
    /// instead of O(visible × N).
    func burstSegment(at index: Int, visible: [PhotoEntry]) -> BurstSegment {
        guard sortMode == .name else { return .none }
        return Self.burstSegment(at: index, in: visible,
                                 ids: burstIDByStem,
                                 sizes: burstSizesByID)
    }

    /// Per-cell segment helper that takes pre-hoisted burst id + size
    /// dicts. Caller (FilmstripView) reads `burstIDByStem` / `burstSizesByID`
    /// ONCE at the top of its body and passes them through so this loop
    /// stays O(1) per cell.
    static func burstSegment(at index: Int, in visible: [PhotoEntry],
                             ids: [String: Int],
                             sizes: [Int: Int]) -> BurstSegment {
        guard visible.indices.contains(index) else { return .none }
        guard let myID = ids[visible[index].stem],
              (sizes[myID] ?? 0) >= 2 else { return .none }

        // Walk through the visible array past non-matching frames
        // (filtered-out siblings, singletons, members of other
        // bursts) looking for another visible member of the same
        // burst. This way a 9-frame burst with frames 2 and 5
        // visible — filters hide 1, 3, 4, 6-9 — still gets a
        // start/end bracket pair instead of two unrelated singletons.
        func hasMatchOn(_ step: Int) -> Bool {
            var i = index + step
            while visible.indices.contains(i) {
                if ids[visible[i].stem] == myID { return true }
                i += step
            }
            return false
        }
        let leftMatches  = hasMatchOn(-1)
        let rightMatches = hasMatchOn(+1)
        switch (leftMatches, rightMatches) {
        case (false, false): return .solo
        case (false, true):  return .start
        case (true,  true):  return .middle
        case (true,  false): return .end
        }
    }

    /// 1-based position + total for a entry inside its burst, or nil for
    /// singletons. Bursts are contiguous in `shoot.entries` (name-order),
    /// so we walk backward from `stem` until the burst id changes.
    func burstPosition(for stem: String) -> (index: Int, total: Int)? {
        burstPositionByStem[stem]
    }

    /// Move to a new entry within the current shoot (clamped). Index is into
    /// `sortedEntries`, i.e. display order.
    ///
    /// Cancels any prior in-flight apply-task so a fast burst doesn't
    /// commit intermediate results. The pipeline's decoded image may
    /// still finish in the background (PreviewDecoder/ImageIO don't honour
    /// granular cancellation), but its result is dropped before
    /// reaching `currentImage` — no SwiftUI re-render, no texture
    /// upload, no histogram compute.
    func navigate(to index: Int) {
        let entries = sortedEntries
        guard !entries.isEmpty else { return }
        let clamped = max(0, min(index, entries.count - 1))
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        PerfTracker.mark("ViewerState.navigate → spawning task")
        currentApplyTask?.cancel()
        currentApplyTask = Task { [weak self] in
            await self?.applyCurrentEntry(resetViewport: false)
        }
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
        let entries = sortedEntries
        guard !entries.isEmpty else { return }
        if let idx = nextVisibleIndex(from: entries.count, direction: -1) {
            navigate(to: idx)
        }
    }

    /// Walk from `from` in `direction` (±1), skipping entries filtered out by
    /// the current show-* toggles. Walks `sortedEntries` (display order).
    /// Returns nil if no visible entry lies in that direction.
    private func nextVisibleIndex(from: Int, direction: Int) -> Int? {
        let entries = sortedEntries
        var i = from + direction
        while entries.indices.contains(i) {
            if isVisible(entries[i]) { return i }
            i += direction
        }
        return nil
    }

    /// Walk `steps` visible entries (sign = direction). Used by ⌥+arrow.
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

    /// Walk `steps` *entry boundaries* (sign = direction). A multi-
    /// frame burst counts as ONE entry — used by ⌥+arrow when
    /// "collapse bursts" is on, so the user moves a uniform 10
    /// thumbs across the (collapsed) filmstrip regardless of how
    /// many raw frames live inside each burst.
    ///
    /// Reuses `nextVisibleIndex` for the per-frame walk; only the
    /// "did we cross into a different entry" check differs. Backward
    /// direction lands on the FIRST frame of the target entry so the
    /// behavior matches ⌘← from the burst-features PR.
    func navigate(byEntries steps: Int) {
        guard steps != 0 else { return }
        let direction = steps > 0 ? 1 : -1
        var idx = currentIndex
        var crossed = 0
        let limit = abs(steps)
        while crossed < limit,
              let next = nextVisibleIndex(from: idx, direction: direction) {
            if !sameBurst(sortedEntries[idx].stem, sortedEntries[next].stem) {
                crossed += 1
            }
            idx = next
        }
        if direction < 0 {
            idx = walkBackToEntryStart(from: idx)
        }
        navigate(to: idx)
    }

    /// From `start`, walk backward through the visible array while
    /// staying inside the same entry (same burst id). Returns the
    /// first frame of that entry. For a singleton or nil-burst-id
    /// entry, returns `start` unchanged.
    private func walkBackToEntryStart(from start: Int) -> Int {
        guard sortedEntries.indices.contains(start) else { return start }
        let id = burstIDByStem[sortedEntries[start].stem]
        // Nil burst id → singleton, can't walk back inside it.
        guard let id else { return start }
        var i = start
        while let prev = nextVisibleIndex(from: i, direction: -1),
              burstIDByStem[sortedEntries[prev].stem] == id {
            i = prev
        }
        return i
    }

    /// True while the indexer is mid-flight. Drives the
    /// collapse-bursts gate below — while indexing the burst-id table
    /// is still being built up batch-by-batch, so collapsing would
    /// hide entries whose siblings haven't been detected yet (the
    /// representative thumb would flip-flop as new burst memberships
    /// land). Forcing off until indexing completes keeps the
    /// filmstrip stable.
    var isIndexingActive: Bool {
        if case .indexing = indexingStatus { return true }
        return false
    }

    /// Mirror of `FilmstripView`'s `@AppStorage(SettingsKey.collapseBursts)`
    /// so navigation handlers can branch on the same toggle without
    /// each call site importing `@AppStorage` itself. Always off
    /// while indexing — see `isIndexingActive`.
    var collapseBurstsActive: Bool {
        guard !isIndexingActive else { return false }
        return AppDefaults.shared.bool(forKey: SettingsKey.collapseBursts)
    }

    /// Jump to the next visible UNRATED entry (rating nil or 0).
    /// `[` / `]` shortcuts. No-op if nothing unrated in that
    /// direction — sit still rather than wrap.
    func nextUnrated()     { walkRated(direction: 1)  }
    func previousUnrated() { walkRated(direction: -1) }

    private func walkRated(direction: Int) {
        var idx = currentIndex
        while let next = nextVisibleIndex(from: idx, direction: direction) {
            let stem = sortedEntries[next].stem
            let rating = entryXMPs[stem]?.rating
            if rating == nil || rating == 0 {
                navigate(to: next)
                return
            }
            idx = next
        }
    }

    /// Move to the first visible frame of the next/previous burst.
    /// `direction` is +1 (next) or −1 (previous). Singletons count
    /// as 1-frame bursts (each one is its own "step"), so this never
    /// skips them. Outside `.name` sort the burst groups aren't
    /// contiguous in the visible array, so we degrade to single-step.
    ///
    /// Both directions land on the FIRST frame of the target burst.
    /// Forward (+1) hits it directly. Backward (-1) first finds the
    /// LAST frame of the previous burst, then walks further back
    /// inside that burst until the id changes again — the last index
    /// with the matching id is the burst's first frame.
    func navigateByBurst(direction: Int) {
        guard direction != 0 else { return }
        guard sortMode == .name,
              sortedEntries.indices.contains(currentIndex) else {
            navigate(by: direction > 0 ? 1 : -1)
            return
        }
        let startStem = sortedEntries[currentIndex].stem
        // Step 1: find the first frame in `direction` that belongs
        // to a DIFFERENT entry from where we started.
        var boundary: Int?
        var idx = currentIndex
        while let next = nextVisibleIndex(from: idx, direction: direction) {
            if !sameBurst(startStem, sortedEntries[next].stem) {
                boundary = next
                break
            }
            idx = next
        }
        guard let boundary else {
            navigate(to: idx)  // already at the first/last entry
            return
        }
        if direction > 0 {
            navigate(to: boundary)  // first frame of the next entry — done
            return
        }
        // Backward: boundary is the LAST frame of the previous entry.
        // Walk back to its first frame.
        let prevStem = sortedEntries[boundary].stem
        var firstOfPrev = boundary
        idx = boundary
        while let prev = nextVisibleIndex(from: idx, direction: -1) {
            if !sameBurst(prevStem, sortedEntries[prev].stem) { break }
            firstOfPrev = prev
            idx = prev
        }
        navigate(to: firstOfPrev)
    }

    /// Two stems belong to the SAME entry only when both have a known
    /// burst id AND those ids are equal. nil burst ids (entries
    /// without a Sony SequenceNumber, JPG-only entries, or entries
    /// not yet seen by the advanced-EXIF pipeline) are each their own
    /// singleton — preventing `navigateByBurst` from treating "two
    /// nils" as the same burst and running off the end.
    func sameBurst(_ a: String, _ b: String) -> Bool {
        guard let ia = burstIDByStem[a], let ib = burstIDByStem[b]
        else { return false }
        return ia == ib
    }

    func toggleRequestedVariant() {
        // No RAW for this entry (standalone HIF / JPG) → no-op.
        // Pressing Z on a preview-only entry has nothing to swap to.
        guard let entry, entry.rawURL != nil else { return }
        requestedVariant = (requestedVariant == .preview) ? .raw : .preview
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
    // MARK: - rating / reject / label mutations
    //
    // Every user-action that writes to currentXMP / entryXMPs starts
    // with `guard !isLoadingDisplayedPair` so the action targets the
    // entry the user actually SEES. Rationale: during a fast nav burst
    // the canvas can lag the navigation intent by ~50–200 ms; a key
    // press in that window would otherwise rate the not-yet-visible
    // entry. Dropping the press is unambiguous — user re-presses once
    // the new image lands. Sidebar buttons that wrap these methods
    // disable themselves on `isLoadingDisplayedPair` so the user can
    // see why their click might not have acted.

    func setRating(_ rating: Int?, source: RatingInputSource = .keyboard) {
        guard !isLoadingDisplayedPair else { return }
        guard let entry else { return }
        metrics.recordScoreSet()
        let previous = currentXMP
        let xmpWasOnDisk = stemsWithXMPOnDisk.contains(entry.stem)
        var updated = currentXMP
        updated.rating = rating
        currentXMP = updated
        // Sidebar (DecisionsPanelView) reads displayedXMP to avoid
        // showing the not-yet-visible nav-intent pair's rating
        // during nav lag. Once the !isLoadingDisplayedPair guard
        // above passes, displayedEntry IS the current entry, so
        // sync the displayed snapshot too — otherwise the sidebar
        // stars/dots/reject button would stay stale until the next
        // navigation.
        if displayedEntry?.stem == entry.stem { displayedXMP = updated }
        entryXMPs[entry.stem] = updated
        stemsWithXMPOnDisk.insert(entry.stem)
        invalidateSortedEntriesCache()
        invalidateShootStatsCache()
        currentEntryFiles.xmp = true
        let capturedEntry = entry

        // Auto-advance only on SET (non-nil) — clearing is usually a "fix
        // this mistake" action, not a decision worth moving past.
        if rating != nil, autoAdvanceAfterRating(source: source) {
            nextPair()
        }

        // Reliable disk write — retry + per-stem serialization +
        // failure surfaced via `failedXMPWrites` / titlebar pill.
        // The optimistic in-memory mutation above is intentionally
        // NOT reverted on failure: it reflects the user's intent
        // and the failure surface (the persistent pill) is what
        // tells them the write didn't make it to disk. Reverting
        // silently after a failure would look like a phantom undo.
        // See project memory `project_xmp_write_reliability.md`.
        Task { await xmpWriter.writeRating(rating, for: capturedEntry) }

        // Register Cmd+Z undo. focusedStem is the entry the user
        // was on BEFORE auto-advance — so undo brings them back to
        // the entry they actually rated. Resolved by stem at apply
        // time (indices may shift if sort changes meanwhile).
        //
        // The explicit begin/end group makes each user action its
        // own undo step even in synchronous test contexts where
        // groupsByEvent's auto-close-on-runloop-tick doesn't fire.
        // Production: nested inside the event-driven group, no
        // user-visible difference.
        let actionName = Self.humanReadableUndoActionName(rating: rating)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { state in
            state.applyXMPSnapshot(
                stem: capturedEntry.stem,
                previousXMP: previous,
                previousXMPWasOnDisk: xmpWasOnDisk,
                focusedStem: capturedEntry.stem,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// R toggles rating between -1 (reject) and nil (clear). Anything else
    /// (existing star rating) is converted to rejected.
    func toggleReject(source: RatingInputSource = .keyboard) {
        let next: Int? = (currentXMP.rating == -1) ? nil : -1
        setRating(next, source: source)
    }

    /// Mutate an arbitrary entry's XMP rating without moving the
    /// canvas focus. Used by `rejectBurstSiblings` so the user stays
    /// on the keeper while the rest of the burst gets ✗-ed. Mirrors
    /// `setRating`'s optimistic + write + rollback shape.
    func setRating(_ rating: Int?, for target: PhotoEntry) {
        metrics.recordScoreSet()
        let previous = entryXMPs[target.stem] ?? .empty
        let xmpWasOnDisk = stemsWithXMPOnDisk.contains(target.stem)
        var updated = previous
        updated.rating = rating
        entryXMPs[target.stem] = updated
        // If we happen to be mutating the displayed entry (e.g.,
        // burst-reject called on a singleton-burst keeps the user
        // on the same entry — but the displayed entry might be one
        // of the siblings the loop hits), sync displayedXMP too so
        // the sidebar reflects the change.
        if displayedEntry?.stem == target.stem { displayedXMP = updated }
        if entry?.stem == target.stem { currentXMP = updated }
        stemsWithXMPOnDisk.insert(target.stem)
        invalidateSortedEntriesCache()
        invalidateShootStatsCache()
        Task { await xmpWriter.writeRating(rating, for: target) }

        // Undo registration. focusedStem is nil — this variant
        // doesn't move the user's selection (it's the batch path
        // used by burst-reject), so undo shouldn't move it either.
        // The outer beginUndoGrouping in rejectBurstSiblings
        // collects all per-sibling groups into one Cmd+Z.
        let actionName = Self.humanReadableUndoActionName(rating: rating)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { state in
            state.applyXMPSnapshot(
                stem: target.stem,
                previousXMP: previous,
                previousXMPWasOnDisk: xmpWasOnDisk,
                focusedStem: nil,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// `g` shortcut: reject other members of the displayed entry's
    /// burst. `scope == .unrated` skips siblings that already have a
    /// rating / label / reject (the common "I've already triaged
    /// these" case). `scope == .all` rejects every sibling. No-op
    /// outside a burst (size < 2) or with no displayed entry.
    func rejectBurstSiblings(scope: GRejectScope) {
        guard let stem = displayedEntry?.stem,
              let id = burstIDByStem[stem],
              (burstSizesByID[id] ?? 0) >= 2 else { return }
        let siblings = sortedEntries.filter {
            $0.stem != stem && burstIDByStem[$0.stem] == id
        }
        // Bundle every per-sibling setRating undo registration
        // into ONE Cmd+Z entry. Standard macOS expectation: one
        // user keypress = one undo step. Without the grouping,
        // the user would have to mash Cmd+Z N times to revert a
        // single G press.
        undoManager.beginUndoGrouping()
        // Register the keeper-jump undo FIRST. NSUndoManager
        // invokes a group's actions in REVERSE registration order,
        // so this runs LAST on Cmd+Z — after every per-sibling
        // revert lands, the user is jumped back to the entry they
        // pressed G on. The keeper navigation is symmetric on
        // redo via recursive re-register inside the handler (the
        // original action was rooted at the keeper, so redo lands
        // there too).
        registerBurstRejectKeeperJump(keeperStem: stem)
        // Set the name BEFORE endUndoGrouping — with
        // groupsByEvent=false (e.g., in tests) setActionName
        // requires an open group; calling it after end fires an
        // NSInternalInconsistencyException.
        defer {
            undoManager.setActionName("Reject Burst Siblings")
            undoManager.endUndoGrouping()
        }
        for sib in siblings {
            let xmp = entryXMPs[sib.stem]
            // "Unrated" = no star rating. A color label alone does
            // NOT protect a sibling — labels are organizational, not
            // a culling decision, and a labeled-but-unscored sibling
            // is still a candidate to reject. Already-rejected
            // siblings (rating == -1) are also skipped (re-reject is
            // a no-op).
            let isUnrated = xmp?.rating == nil || xmp?.rating == 0
            switch scope {
            case .unrated:
                if isUnrated { setRating(-1, for: sib) }
            case .all:
                setRating(-1, for: sib)
            }
        }
    }

    /// Burst-reject keeper-navigation undo. Registered at the head
    /// of the burst-reject group so it executes LAST on Cmd+Z; the
    /// recursive re-register inside the handler makes redo
    /// symmetric (both undo AND redo navigate back to the entry
    /// the user pressed G on). Stem is resolved at apply time, so
    /// a sort/filter reorder between the action and the undo
    /// doesn't misdirect.
    private func registerBurstRejectKeeperJump(keeperStem: String) {
        undoManager.registerUndo(withTarget: self) { state in
            if let idx = state.sortedEntries.firstIndex(where: { $0.stem == keeperStem }) {
                state.navigate(to: idx)
            }
            state.registerBurstRejectKeeperJump(keeperStem: keeperStem)
        }
    }

    /// Pressing the same star key again clears the rating. From any other
    /// state (different stars or reject), sets to the requested value.
    func toggleRating(_ rating: Int, source: RatingInputSource = .keyboard) {
        setRating(currentXMP.rating == rating ? nil : rating, source: source)
    }

    /// Sets the XMP color label, or clears it (nil). Optimistic with rollback.
    func setLabel(_ label: String?, source: RatingInputSource = .keyboard) {
        guard !isLoadingDisplayedPair else { return }
        guard let entry else { return }
        metrics.recordScoreSet()
        let previous = currentXMP
        let xmpWasOnDisk = stemsWithXMPOnDisk.contains(entry.stem)
        var updated = currentXMP
        updated.label = label
        currentXMP = updated
        // Sidebar reads displayedXMP — keep it in sync after the
        // guard confirms displayedEntry == entry.
        if displayedEntry?.stem == entry.stem { displayedXMP = updated }
        entryXMPs[entry.stem] = updated
        stemsWithXMPOnDisk.insert(entry.stem)
        invalidateSortedEntriesCache()
        invalidateShootStatsCache()
        currentEntryFiles.xmp = true
        let capturedEntry = entry

        if label != nil, autoAdvanceAfterRating(source: source) {
            nextPair()
        }

        Task { await xmpWriter.writeLabel(label, for: capturedEntry) }

        // Undo registration. Same shape as setRating — focusedStem
        // is the labeled entry so undo brings the user back even
        // after auto-advance.
        let actionName = Self.humanReadableUndoActionName(label: label)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { state in
            state.applyXMPSnapshot(
                stem: capturedEntry.stem,
                previousXMP: previous,
                previousXMPWasOnDisk: xmpWasOnDisk,
                focusedStem: capturedEntry.stem,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Click same color again clears.
    func toggleLabel(_ label: String, source: RatingInputSource = .keyboard) {
        setLabel(currentXMP.label == label ? nil : label, source: source)
    }

    // MARK: - Undo / Redo apply path
    //
    // Every XMP-mutating method registers an undo via
    // `applyXMPSnapshot(...)`. That same method runs both undo and
    // redo (registering its own inverse at the end) so the stack
    // works symmetrically without separate apply/unapply pairs.
    //
    // **Stem-based everywhere.** No captured indices anywhere in
    // the undo data — indices shift across sort, filter, and
    // indexer reorders, and would silently misdirect on apply.
    // Resolution from stem happens at apply time so the user
    // always ends up on the right entry.

    /// Apply a snapshot of a single entry's XMP state, register
    /// the inverse for redo, and (if requested) jump selection.
    /// Called from each undo registration in the mutators and
    /// recursively by NSUndoManager during redo.
    @MainActor
    fileprivate func applyXMPSnapshot(
        stem: String,
        previousXMP: XMPSidecar,
        previousXMPWasOnDisk: Bool,
        focusedStem: String?,
        actionName: String
    ) {
        guard let entry = shoot?.entries.first(where: { $0.stem == stem }) else { return }
        // Snapshot the CURRENT state for the redo registration.
        let nextXMP        = entryXMPs[stem] ?? .empty
        let nextWasOnDisk  = stemsWithXMPOnDisk.contains(stem)
        // For the inverse we want to remember where the user is
        // RIGHT NOW (after the previous apply) so redo can bring
        // them back. If the original action didn't request a
        // selection jump (focusedStem == nil — e.g., the per-stem
        // path used by burst-reject), keep nil through redo too.
        let nextFocusedStem: String? = focusedStem.flatMap { _ in self.entry?.stem }

        // Apply the reverted state in-memory.
        entryXMPs[stem] = previousXMP
        if previousXMPWasOnDisk {
            stemsWithXMPOnDisk.insert(stem)
        } else {
            stemsWithXMPOnDisk.remove(stem)
        }
        if self.entry?.stem == stem { currentXMP = previousXMP }
        // Sidebar reads displayedXMP — keep it in sync so undo
        // visibly updates the stars / label / reject button.
        if displayedEntry?.stem == stem { displayedXMP = previousXMP }
        invalidateSortedEntriesCache()
        invalidateShootStatsCache()

        // Reliable disk write — same path as first-time writes.
        // Coordinator serializes per-stem, so if the original
        // write is still in flight when undo fires, the revert
        // queues behind it (correct: the file ends up with the
        // reverted value, not the half-applied original).
        Task { await xmpWriter.writeRating(previousXMP.rating, for: entry) }
        Task { await xmpWriter.writeLabel(previousXMP.label, for: entry) }

        // Ensure the reverted entry is visible under the current
        // filters — otherwise undo would silently hide it.
        ensureFilterShows(xmp: previousXMP)

        // Jump selection if requested. Resolve from stem AT APPLY
        // TIME so any sort/filter reorder between the action and
        // the undo doesn't misdirect.
        if let focusedStem,
           let idx = sortedEntries.firstIndex(where: { $0.stem == focusedStem }) {
            navigate(to: idx)
        }

        // Register the inverse for redo (or the next undo).
        undoManager.registerUndo(withTarget: self) { state in
            state.applyXMPSnapshot(
                stem: stem,
                previousXMP: nextXMP,
                previousXMPWasOnDisk: nextWasOnDisk,
                focusedStem: nextFocusedStem,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
    }

    /// Flip filter toggles as needed so an entry with the given
    /// XMP would be visible. Called from `applyXMPSnapshot` so
    /// undo never silently hides the entry it just reverted.
    /// `showRejected` / `showUnrated` / `showStars` already have
    /// `didSet` invalidation hooks (filmstrip auto-updates).
    private func ensureFilterShows(xmp: XMPSidecar) {
        switch ratingCategory(for: xmp) {
        case .rejected:
            if !showRejected { showRejected = true }
        case .rated(let stars):
            if !showStars.contains(stars) { showStars.insert(stars) }
        case .unrated:
            if !showUnrated { showUnrated = true }
        }
    }

    /// `ratingCategory(for:)` takes a stem; this overload takes an
    /// XMP directly so we can classify a snapshot that hasn't been
    /// stored in `entryXMPs` yet (the undo apply path computes the
    /// category from the snapshot's contents, not from current
    /// state).
    private func ratingCategory(for xmp: XMPSidecar) -> RatingCategory {
        if xmp.isReject { return .rejected }
        if let stars = xmp.starCount, stars > 0 { return .rated(stars: stars) }
        return .unrated
    }

    fileprivate static func humanReadableUndoActionName(rating: Int?) -> String {
        switch rating {
        case nil: return "Clear Rating"
        case -1:  return "Reject"
        case 0:   return "Clear Rating"
        case let n?: return "Rate \(n) Star\(n == 1 ? "" : "s")"
        }
    }

    fileprivate static func humanReadableUndoActionName(label: String?) -> String {
        if let label, !label.isEmpty { return "Set Label \(label)" }
        return "Clear Label"
    }

    func cycleDecoder() {
        guard entry != nil else { return }
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

        // Skip when there's no RAW to swap to (standalone HIF / JPG).
        guard autoSwapEnabled, let entry, entry.rawURL != nil else { return }
        if curr >= 1.0 && prev < 1.0 && requestedVariant == .preview {
            #if DEBUG
            Log.app.notice("auto-swap: preview → RAW (pz \(prev, format: .fixed(precision: 2)) → \(curr, format: .fixed(precision: 2)))")
            #endif
            requestedVariant = .raw
            await applyRequestedVariant()
        }
    }

    /// Apply everything for the current entry. Metadata (EXIF, AF, XMP,
    /// thumbnails, SequenceNumber) comes from the indexer's caches — this
    /// method does NOT spawn any metadata Task. If the cache is cold for
    /// the entry, the view shows empty/placeholder state and we signal the
    /// indexer to bump that batch to the head of every pipeline; the flush
    /// methods will fill `currentXxx` when the batch lands.
    private func applyCurrentEntry(resetViewport: Bool) async {
        guard let entry else { return }
        PerfTracker.mark("applyCurrentEntry entered")
        // Keep currentImage as-is so the previous frame stays on screen until
        // the new one decodes — avoids a flash to ProgressView (which would
        // tear down the ImageCanvasView and lose SwiftUI focus).
        self.errorMessage = nil
        self.displayedVariant = .preview
        self.requestedVariant = .preview
        if resetViewport {
            self.viewport = .identity
            self.currentPixelZoom = 1.0
        }
        let af = entryAFData[entry.stem]
        self.currentExif        = entryExif[entry.stem]
        self.currentAFRegions   = af?.regions ?? []
        self.currentAFSettings  = af?.settings ?? AFSettings()
        self.currentXMP         = entryXMPs[entry.stem] ?? .empty
        self.currentEntryFiles   = entryFiles(for: entry)
        PerfTracker.mark("applyCurrentEntry: cache reads + entryFiles done")
        prioritizeBatch(forStem: entry.stem)
        PerfTracker.mark("applyCurrentEntry: prioritizeBatch done")
        await applyRequestedVariant()
        PerfTracker.mark("applyCurrentEntry: applyRequestedVariant returned")
        prefetchNeighborHEIFs()
        PerfTracker.mark("applyCurrentEntry: prefetchNeighborHEIFs spawned")
    }

    /// Pure-Swift derivation: zero disk reads. The arw / hif / jpg slots
    /// are stable for the lifetime of the entry within a shoot (cards
    /// are read-only for PhotoX; mid-session add/remove on writable
    /// disks would require a re-scan anyway). XMP presence comes from
    /// `stemsWithXMPOnDisk`, populated by the XMP indexer pipeline and
    /// by rating-mutator writes. Replaces the 12 `fileExists` probes
    /// the per-nav badge computation used to do — the prime cause of
    /// the nav-perf regression since v0.182.0.
    private func entryFiles(for entry: PhotoEntry) -> EntryFiles {
        let ext = entry.previewURL.pathExtension.lowercased()
        return EntryFiles(
            arw: entry.rawURL != nil,
            hif: ext == "hif" || ext == "heif" || ext == "heic",
            jpg: ext == "jpg" || ext == "jpeg",
            xmp: stemsWithXMPOnDisk.contains(entry.stem)
        )
    }

    /// Warm the MTLTextureCache for neighbours of `currentIndex` so the
    /// next arrow-key press renders without an upload. Decodes + uploads
    /// (NOT just decodes) because we dropped the DecodedImage cache —
    /// the texture IS the cached artifact now.
    ///
    /// Cancels prefetches for stems that are NO LONGER neighbours (the
    /// user navigated away), to avoid wasting GPU time on textures we
    /// won't display soon. Per-stem dedup via `prefetchTasks` so an
    /// already-queued prefetch isn't restarted.
    ///
    /// Bounded to ±1 (immediate next + previous). Wider radii thrash
    /// the Metal upload pipeline + competed with user-initiated uploads
    /// (~600 ms per nav was observed at ±2). Keep it tight so user nav
    /// gets the GPU first.
    private func prefetchNeighborHEIFs() {
        let entries = sortedEntries
        // Prefetch radius from Settings → Advanced. Clamped to [0, 3]
        // — 0 disables prefetch entirely; >3 has never been tested and
        // the GPU upload pipeline contention at ±2+ is already
        // documented above. `integer(forKey:)` returns 0 for missing
        // keys, which we explicitly fall back to the default.
        let stored = AppDefaults.shared.object(forKey: SettingsKey.prefetchRadius) as? Int
        let radius = max(0, min(3, stored ?? SettingsKey.Defaults.prefetchRadius))
        guard radius > 0 else {
            // Cancel any in-flight prefetches and bail.
            for (_, task) in prefetchTasks { task.cancel() }
            prefetchTasks.removeAll()
            return
        }
        let neighborOffsets = (1 ... radius).flatMap { [-$0, $0] }
        let neighborIndices = neighborOffsets
            .map { currentIndex + $0 }
            .filter { entries.indices.contains($0) }
        let neighborStems = Set(neighborIndices.map { entries[$0].stem })

        // Drop any prefetches for stems no longer in the neighbour set.
        for (stem, task) in prefetchTasks where !neighborStems.contains(stem) {
            task.cancel()
            prefetchTasks[stem] = nil
        }

        // Spawn / dedupe prefetches for the current neighbours.
        for idx in neighborIndices {
            let neighbor = entries[idx]
            let stem = neighbor.stem
            if prefetchTasks[stem] != nil { continue }
            let key = DecodeKey(entryID: neighbor.id, variant: .preview, decoder: .imageIO)
            prefetchTasks[stem] = Task { [weak self] in
                guard let self else { return }
                if Task.isCancelled { return }
                let decoded: DecodedImage?
                do {
                    decoded = try await self.pipeline.decode(
                        entry: neighbor, variant: .preview, decoder: .imageIO
                    )
                } catch {
                    decoded = nil
                }
                if Task.isCancelled { return }
                if let decoded {
                    _ = try? await MTLTextureCache.shared.warm(
                        cgImage: decoded.cgImage,
                        key: key,
                        orientation: decoded.orientation
                    )
                }
                // Self-cleanup — remove the slot so the next prefetch
                // round can spawn a replacement if needed.
                if !Task.isCancelled {
                    self.prefetchTasks[stem] = nil
                }
            }
        }
    }

    private func kickOffHistogramCompute(for image: DecodedImage) {
        guard let stem = entry?.stem else { return }
        histogramGeneration += 1
        let gen = histogramGeneration
        // Cache hit — surface instantly, no Task spawn.
        if let cached = entryHistograms[stem] {
            currentHistogram = cached
            return
        }
        let cgImage = image.cgImage
        Task { [weak self] in
            let h = await Task.detached(priority: .utility) {
                HistogramComputer.compute(from: cgImage)
            }.value
            guard let self else { return }
            guard self.histogramGeneration == gen else { return }
            self.currentHistogram = h
            self.entryHistograms[stem] = h
        }
    }

    private func applyRequestedVariant() async {
        guard let entry else { return }
        let variant = requestedVariant
        let chosenDecoder = decoder
        // HEIF always goes through the imageIO decoder slot — match
        // DecodePipeline.decode's keyDecoder normalisation so the
        // canvas's MTLTextureCache key lines up with whatever the
        // pipeline produced.
        let keyDecoder: DecoderChoice = (variant == .preview) ? .imageIO : chosenDecoder
        let key = DecodeKey(entryID: entry.id, variant: variant, decoder: keyDecoder)
        self.errorMessage = nil
        self.isDecoding = true
        defer { isDecoding = false }

        // FAST PATH — both texture and histogram caches hit. Skip
        // pipeline.decode entirely (saves ~100 ms per revisit on a
        // Sony A1 II HEIF — even with PreviewBytesCache hit, ImageIO's
        // re-decode is the bottleneck on A↔B↔A↔B nav). The canvas's
        // `ImageCanvasView` is wired to call `setImage` on key change
        // even when the CGImage instance is the same, so the cached
        // texture binds correctly. `currentImage` stays pointing at
        // whatever entry the canvas LAST decoded — its `cgImage` is
        // unused by the cache-hit setImage path; readers of pixelSize
        // already moved to `displayedPixelSize`.
        if !Task.isCancelled,
           MTLTextureCache.shared.get(key) != nil,
           let cachedHist = entryHistograms[entry.stem]
        {
            PerfTracker.mark("applyRequestedVariant fast-path (texture + histogram cached)")
            self.currentImageKey = key
            self.currentHistogram = cachedHist
            self.displayedVariant = variant
            return
        }

        do {
            PerfTracker.mark("about to await pipeline.decode")
            let decoded = try await pipeline.decode(entry: entry, variant: variant, decoder: chosenDecoder)
            PerfTracker.mark("pipeline.decode returned")
            // Drop the result if the user navigated past or switched
            // variant/decoder while the decode was in flight. The
            // decoded image is harmless — it just isn't pushed into
            // currentImage (no SwiftUI re-render, no texture upload,
            // no histogram compute).
            guard !Task.isCancelled else { return }
            guard variant == self.requestedVariant, chosenDecoder == self.decoder else { return }
            self.currentImage = decoded
            self.currentImageKey = key
            PerfTracker.mark("currentImage set")
            self.displayedVariant = variant
            kickOffHistogramCompute(for: decoded)
        } catch {
            // Cancellation throws too — silently swallow so it doesn't
            // surface as an "error" in the sidebar.
            if Task.isCancelled { return }
            Log.app.error("applyRequestedVariant: \(String(describing: error), privacy: .public)")
            self.errorMessage = String(describing: error)
        }
    }
}
