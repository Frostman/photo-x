import Foundation
import CoreGraphics
import IndexingCore

/// Pre-computed bucketing of every entry in a shoot into the work
/// the indexer pipelines actually need to do, plus whatever the cache
/// can pre-populate before the streams start. Built once at the top
/// of `ViewerState.startIndexing()` by walking `shoot.entries` and
/// calling `cache.entry(for:fingerprint:)` once per entry.
///
/// Replaces the previous per-batch "look up cache, run work, flush"
/// loop with "look up cache once, then queue only the missing work,
/// flush throttled."
struct IndexingWorkPlan {
    /// Entries with cached thumbnail JPEG bytes — Stream A
    /// (`runThumbDecodePipeline`) decodes them in parallel without
    /// re-reading the source file.
    var cachedThumbBytes: [(entry: PhotoEntry, bytes: Data, orientation: Int)]

    /// Entries the basic-EXIF cache doesn't cover (no thumbnail
    /// bytes OR no exif). Stream B reads the source file and
    /// extracts both, then hands the resulting JPEG bytes off to
    /// the decode pool.
    var needsBasicFetch: [PhotoEntry]

    /// Entries the advanced-EXIF cache doesn't cover (no afData
    /// AND no sequenceNumber). Stream C spawns exiftool one-shot
    /// batches for these.
    var needsAdvancedExif: [PhotoEntry]

    /// Entries whose folder listing carried a sibling .xmp
    /// (`shoot.xmpStems`). Stream D reads each one. Already gated
    /// at the scan level so this is just the existing
    /// `shoot.xmpStems` projected onto the actual `PhotoEntry`s.
    var needsXMP: [PhotoEntry]

    /// Cached EXIF / AF / sequenceNumber to apply to the
    /// `ViewerState.entryExif` / `entryAFData` / `entrySequenceNumber`
    /// maps in a single MainActor batch right after the plan
    /// completes. Makes the sidebar show real data immediately,
    /// before any decode or pipeline finishes.
    var prepopulatedExif: [String: ExifSummary]
    var prepopulatedAFData: [String: ExifToolRunner.AFData]
    var prepopulatedSequenceNumber: [String: Int]

    /// Counts of cache lookups by outcome — used by ViewerState
    /// to bump the @Observable hit / miss counters at plan time
    /// instead of waiting for the pipelines to run (which they
    /// don't, for a fully-cached shoot).
    var sidecarHits: Int
    var localCacheHits: Int
    var misses: Int

    /// Build a plan from the shoot + cache. `fingerprints` is
    /// expected to already match `shoot.previewFingerprints` (or a
    /// stale empty dict — entries with no fingerprint are treated
    /// as cache misses).
    @MainActor
    static func make(shoot: Shoot,
                     fingerprints: [String: IndexerCache.Fingerprint],
                     cache: IndexerCache,
                     xmpStems: Set<String>) -> IndexingWorkPlan {
        var cachedThumbBytes: [(entry: PhotoEntry, bytes: Data, orientation: Int)] = []
        var needsBasicFetch:    [PhotoEntry] = []
        var needsAdvancedExif:  [PhotoEntry] = []
        var needsXMP:           [PhotoEntry] = []
        var prepopExif: [String: ExifSummary] = [:]
        var prepopAFData: [String: ExifToolRunner.AFData] = [:]
        var prepopSeq:    [String: Int] = [:]
        var sidecarHits = 0
        var localCacheHits = 0
        var misses = 0

        cachedThumbBytes.reserveCapacity(shoot.entries.count)
        prepopExif.reserveCapacity(shoot.entries.count)
        prepopAFData.reserveCapacity(shoot.entries.count)
        prepopSeq.reserveCapacity(shoot.entries.count)

        for entry in shoot.entries {
            if xmpStems.contains(entry.stem) {
                needsXMP.append(entry)
            }
            guard let fp = fingerprints[entry.stem],
                  let hit = cache.entry(for: entry.stem, fingerprint: fp) else {
                // No fingerprint OR cache miss — entry needs both
                // streams' full work.
                misses += 1
                needsBasicFetch.append(entry)
                needsAdvancedExif.append(entry)
                continue
            }
            switch hit.source {
            case .sidecar:    sidecarHits += 1
            case .localCache: localCacheHits += 1
            }
            // Pre-populate everything the cache covers.
            if let exif = hit.exif {
                prepopExif[entry.stem] = exif
            }
            if let af = hit.afData {
                prepopAFData[entry.stem] = af
            }
            if let seq = hit.sequenceNumber {
                prepopSeq[entry.stem] = seq
            }

            // Bucket the remaining work.
            if let bytes = hit.thumbnailJPEG {
                cachedThumbBytes.append((entry, bytes,
                                          hit.thumbnailOrientation ?? 1))
            } else if hit.exif == nil {
                // Missing both thumb bytes AND exif — Stream B
                // reads the source for both.
                needsBasicFetch.append(entry)
            }
            // afData OR sequenceNumber missing → run exiftool.
            if hit.afData == nil && hit.sequenceNumber == nil {
                needsAdvancedExif.append(entry)
            }
        }

        return IndexingWorkPlan(
            cachedThumbBytes: cachedThumbBytes,
            needsBasicFetch: needsBasicFetch,
            needsAdvancedExif: needsAdvancedExif,
            needsXMP: needsXMP,
            prepopulatedExif: prepopExif,
            prepopulatedAFData: prepopAFData,
            prepopulatedSequenceNumber: prepopSeq,
            sidecarHits: sidecarHits,
            localCacheHits: localCacheHits,
            misses: misses
        )
    }
}

/// Generic actor-protected buffer with a strict ≥300 ms flush
/// cadence. Pipelines `append` results into one of these; a sibling
/// ticker task wakes every 300 ms and drains whatever has piled up,
/// then hops to MainActor to apply the changes to the `@Observable`
/// state maps.
///
/// Bounds the worst-case main-actor work per flush to "the results
/// from one 300 ms window" and gives the runloop ≥3 frames of
/// breathing room between flushes — input events and the canvas
/// stay responsive even when the indexer is busy.
actor IndexingFlushBuffer<Item: Sendable> {
    /// Strict flush cadence. 300 ms = 18 frames at 60 Hz; SwiftUI
    /// sees at most ~3 invalidations per second per stream.
    static var minIntervalNanos: UInt64 { 300_000_000 }

    private var buffer: [Item] = []

    /// Append a single item. Cheap; never blocks beyond actor hop.
    func append(_ item: Item) {
        buffer.append(item)
    }

    /// Append a batch of items at once. Used by streams that
    /// produce items in groups (e.g. one batch finishing).
    func append(contentsOf items: [Item]) {
        buffer.append(contentsOf: items)
    }

    /// Pull everything buffered and reset. Caller is expected to
    /// hop to MainActor and apply the items to whatever state maps
    /// they belong to.
    func drain() -> [Item] {
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        return out
    }

    /// True when the buffer is empty — saves an unnecessary
    /// MainActor hop in the ticker when there's nothing to flush.
    var isEmpty: Bool { buffer.isEmpty }
}

/// Tiny actor wrapper around an array-as-FIFO so N parallel workers
/// can pull items off without racing. The decode pool in
/// `runThumbDecodePipeline` uses this to feed `processorCount`
/// workers off a shared list of work items.
actor AsyncCursor<Item: Sendable> {
    private var items: [Item]
    private var index: Int = 0

    init(items: [Item]) {
        self.items = items
    }

    func next() -> Item? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

