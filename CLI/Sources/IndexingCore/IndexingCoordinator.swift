import Foundation

/// Folder → `ShootSidecarIndex` orchestrator. Used by the
/// `photox-indexer` CLI on the NAS; the macOS app has its own
/// UI-aware coordinator in `ViewerState`. Both share the per-entry
/// extraction primitives (`MetadataBatchLoader`, `HEIFEmbeddedThumbnail`,
/// `JPEGEmbeddedThumbnail`, `TIFFEXIFParser`) below them.
///
/// Pipelines mirror the macOS shape so per-file output is identical:
///  - Stage 1: fingerprint pre-pass (size + mtimeNanos for every file).
///    Cheap; runs sequentially because filesystem stat is already fast.
///  - Stage 2 (parallel with stage 3): exiftool one-shot per
///    `advancedExifBatchSize` batch for Sony AF + sequence number.
///    Skipped (empty results) if exiftool is missing.
///  - Stage 3: embedded thumbnail + TIFF EXIF parse on the preview
///    file. No subprocess; pure in-process.
///
/// XMP sidecars are intentionally NOT read — they're user data, live
/// next to the photos, and the macOS app reads them directly on shoot
/// open. Mirroring them into the sidecar would force a sidecar rewrite
/// on every star/label change.
public struct IndexingCoordinator: Sendable {

    public struct Progress: Sendable, Hashable {
        public var totalEntries: Int
        public var fingerprintsDone: Int
        public var advancedExifDone: Int
        public var basicExifAndThumbsDone: Int
        public init(totalEntries: Int = 0,
                    fingerprintsDone: Int = 0,
                    advancedExifDone: Int = 0,
                    basicExifAndThumbsDone: Int = 0) {
            self.totalEntries = totalEntries
            self.fingerprintsDone = fingerprintsDone
            self.advancedExifDone = advancedExifDone
            self.basicExifAndThumbsDone = basicExifAndThumbsDone
        }
    }

    public let shootFolder: URL
    /// Concurrency for both pipelines. Default = cpu count; the CLI
    /// exposes `--workers N` to override.
    public let workerCount: Int
    /// Batch size for the exiftool one-shot. Matches the macOS app's
    /// default (50). Smaller batches reduce per-failure cost but pay
    /// more spawn overhead.
    public let advancedExifBatchSize: Int
    public let indexerVersion: String
    public let progress: @Sendable (Progress) -> Void

    public init(shootFolder: URL,
                workerCount: Int = ProcessInfo.processInfo.activeProcessorCount,
                advancedExifBatchSize: Int = 50,
                indexerVersion: String,
                progress: @escaping @Sendable (Progress) -> Void = { _ in }) {
        self.shootFolder = shootFolder
        self.workerCount = max(1, workerCount)
        self.advancedExifBatchSize = max(1, advancedExifBatchSize)
        self.indexerVersion = indexerVersion
        self.progress = progress
    }

    // MARK: - Run

    public func run() async -> ShootSidecarIndex {
        let shoot = ShootScanner.scan(folder: shootFolder)
        guard !shoot.entries.isEmpty else {
            return ShootSidecarIndex(
                version: ShootSidecarIndex.currentSchemaVersion,
                indexedAt: Date(),
                indexerVersion: indexerVersion,
                entries: [:]
            )
        }
        let total = shoot.entries.count
        let counters = ProgressCounters(total: total, progress: progress)
        await counters.emitNow()

        // Stage 1: fingerprints. Sequential — stat is microseconds.
        // Always fingerprints the previewURL (HIF/JPG), NOT the
        // RAW, even when both exist — the macOS app does the
        // same. Mixing the two surfaces as "sidecar entries
        // never match" because RAW and preview share a stem but
        // have different mtimes (the camera writes them in the
        // same burst but they're separate file system objects).
        var fingerprints: [String: IndexFingerprint] = [:]
        fingerprints.reserveCapacity(total)
        for entry in shoot.entries {
            if let fp = try? Self.fingerprint(of: entry.previewURL) {
                fingerprints[entry.stem] = fp
            }
            await counters.bumpFingerprint()
        }

        // Stages 2 + 3 run concurrently.
        async let advancedTask: [String: AdvancedResult] = runAdvancedExif(
            entries: shoot.entries, counters: counters
        )
        async let basicTask: [String: BasicResult] = runBasicExifAndThumbs(
            entries: shoot.entries, counters: counters
        )

        let advanced = await advancedTask
        let basic    = await basicTask

        var indexEntries: [String: IndexEntry] = [:]
        indexEntries.reserveCapacity(total)
        for entry in shoot.entries {
            guard let fp = fingerprints[entry.stem] else { continue }
            let adv = advanced[entry.stem]
            let bas = basic[entry.stem]
            indexEntries[entry.stem] = IndexEntry(
                fingerprint: fp,
                exif: bas?.exif,
                afData: adv?.af,
                sequenceNumber: adv?.sequenceNumber,
                thumbnailJPEG: bas?.thumbnailJPEG,
                thumbnailOrientation: bas?.thumbnailOrientation
            )
        }

        return ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(),
            indexerVersion: indexerVersion,
            entries: indexEntries
        )
    }

    // MARK: - Stage 2: advanced EXIF (exiftool)

    private struct AdvancedResult: Sendable {
        var af: ExifToolRunner.AFData?
        var sequenceNumber: Int?
    }

    private func runAdvancedExif(entries: [PhotoEntry],
                                 counters: ProgressCounters) async -> [String: AdvancedResult] {
        // Build batches of preview URLs. The macOS app's advanced-EXIF
        // pipeline runs exiftool against `entry.previewURL` (HIF/JPG)
        // too — Sony MakerNotes carry the AF data into the embedded
        // preview, and using the same source on both sides keeps the
        // sidecar's AF / sequence values byte-identical to what the
        // app would produce locally.
        let urlPairs: [(stem: String, url: URL)] = entries.map { entry in
            (entry.stem, entry.previewURL)
        }
        let batches: [[(stem: String, url: URL)]]
            = stride(from: 0, to: urlPairs.count, by: advancedExifBatchSize).map {
                Array(urlPairs[$0 ..< min($0 + advancedExifBatchSize, urlPairs.count)])
            }
        guard !batches.isEmpty else { return [:] }

        let workerCount = self.workerCount
        return await withTaskGroup(of: [String: AdvancedResult].self) { group in
            let dispatcher = IndexDispatcher(count: batches.count)
            for _ in 0 ..< min(workerCount, batches.count) {
                group.addTask {
                    var local: [String: AdvancedResult] = [:]
                    while let idx = await dispatcher.next() {
                        let batch = batches[idx]
                        var pathToStem: [String: String] = [:]
                        pathToStem.reserveCapacity(batch.count)
                        for pair in batch { pathToStem[pair.url.path] = pair.stem }
                        let urls = batch.map { $0.url }
                        let result = await MetadataBatchLoader.read(urls)
                        for (sourcePath, af) in result.af {
                            if let stem = pathToStem[sourcePath] {
                                local[stem, default: AdvancedResult()].af = af
                            }
                        }
                        for (sourcePath, seq) in result.seq {
                            if let stem = pathToStem[sourcePath] {
                                local[stem, default: AdvancedResult()].sequenceNumber = seq
                            }
                        }
                        await counters.bumpAdvanced(by: batch.count)
                    }
                    return local
                }
            }

            var merged: [String: AdvancedResult] = [:]
            for await local in group {
                for (k, v) in local {
                    merged[k] = v
                }
            }
            return merged
        }
    }

    // MARK: - Stage 3: basic EXIF + thumbnail

    private struct BasicResult: Sendable {
        var exif: ExifSummary?
        var thumbnailJPEG: Data?
        var thumbnailOrientation: Int?
    }

    private func runBasicExifAndThumbs(entries: [PhotoEntry],
                                       counters: ProgressCounters) async -> [String: BasicResult] {
        let workerCount = self.workerCount
        return await withTaskGroup(of: [String: BasicResult].self) { group in
            let dispatcher = IndexDispatcher(count: entries.count)
            for _ in 0 ..< min(workerCount, entries.count) {
                group.addTask {
                    var local: [String: BasicResult] = [:]
                    while let idx = await dispatcher.next() {
                        let entry = entries[idx]
                        let result = Self.basicExifAndThumb(for: entry)
                        local[entry.stem] = result
                        await counters.bumpBasic()
                    }
                    return local
                }
            }
            var merged: [String: BasicResult] = [:]
            for await local in group {
                for (k, v) in local {
                    merged[k] = v
                }
            }
            return merged
        }
    }

    /// Pure helper — given an entry, return the extracted ExifSummary,
    /// thumbnail JPEG bytes, and orientation. nil fields when the file
    /// doesn't yield them (fast-path miss; macOS will fill in on
    /// first view via its ImageIO fallback).
    private static func basicExifAndThumb(for entry: PhotoEntry) -> BasicResult {
        let url = entry.previewURL
        let ext = url.pathExtension.lowercased()
        var out = BasicResult()
        if ["hif", "heif", "heic"].contains(ext) {
            if let extracted = try? HEIFEmbeddedThumbnail.extract(from: url) {
                if !extracted.jpeg.isEmpty {
                    out.thumbnailJPEG = extracted.jpeg
                    out.thumbnailOrientation = extracted.exifOrientation
                }
                if let exifBytes = extracted.exifBytes,
                   let exif = TIFFEXIFParser.parse(exifBytes) {
                    out.exif = exif
                }
            }
            return out
        }
        if ["jpg", "jpeg"].contains(ext) {
            if let extracted = try? JPEGEmbeddedThumbnail.extract(from: url) {
                if !extracted.jpeg.isEmpty {
                    out.thumbnailJPEG = extracted.jpeg
                    out.thumbnailOrientation = extracted.exifOrientation
                }
                if let exifBytes = extracted.exifBytes,
                   let exif = TIFFEXIFParser.parse(exifBytes) {
                    out.exif = exif
                }
            }
            return out
        }
        return out
    }

    // MARK: - Fingerprint

    public static func fingerprint(of url: URL) throws -> IndexFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let mtimeNanos = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
        return IndexFingerprint(size: size, mtimeNanos: mtimeNanos)
    }
}

// MARK: - Work dispatcher

/// Hands out integer indices one at a time so N worker tasks can
/// race for work without claiming the same item twice.
private actor IndexDispatcher {
    private let total: Int
    private var nextIdx: Int = 0
    init(count: Int) { self.total = count }
    func next() -> Int? {
        guard nextIdx < total else { return nil }
        defer { nextIdx += 1 }
        return nextIdx
    }
}

// MARK: - Progress counters

private actor ProgressCounters {
    private let total: Int
    private let report: @Sendable (IndexingCoordinator.Progress) -> Void
    private var fingerprints = 0
    private var advanced = 0
    private var basic = 0

    init(total: Int, progress: @escaping @Sendable (IndexingCoordinator.Progress) -> Void) {
        self.total = total
        self.report = progress
    }
    func bumpFingerprint() { fingerprints += 1; emit() }
    func bumpAdvanced(by n: Int) { advanced += n; emit() }
    func bumpBasic() { basic += 1; emit() }
    func emitNow() { emit() }
    private func emit() {
        report(.init(totalEntries: total,
                     fingerprintsDone: fingerprints,
                     advancedExifDone: advanced,
                     basicExifAndThumbsDone: basic))
    }
}
