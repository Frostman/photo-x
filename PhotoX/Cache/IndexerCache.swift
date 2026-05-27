import CryptoKit
import Foundation

/// On-disk cache for expensive indexer outputs, scoped per
/// shoot. Keyed by `image path + size + mtime` so a re-open of
/// the same shoot skips the indexer for files that haven't
/// changed.
///
/// Stored as one binary `.plist` per shoot at
/// `~/Library/Caches/PhotoX/IndexerCache/<sha256(path)>.plist`.
/// macOS handles purge under disk pressure; a user-configurable
/// max-total-size triggers LRU eviction of whole-shoot files as
/// a backstop.
///
/// Histograms are NOT cached — they're computed lazily on
/// sidebar view, so hit rate on a re-open is too low to justify
/// the storage cost.
@MainActor
final class IndexerCache {

    // MARK: - Policy

    struct Policy: Sendable {
        var cacheExifSummary  = true
        var cacheAFData       = true
        var cacheSequence     = true
        var cacheThumbnail    = true
        /// Cap on the aggregate size of all shoot caches. When
        /// exceeded, `gcIfNeeded` deletes oldest-mtime .plists
        /// until under the cap. Default 2 GB — enough for ~10
        /// large shoots.
        var maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024
    }

    /// Live policy snapshot, read at each update / flush. Set
    /// once at app launch from UserDefaults; mutated by Settings
    /// when the user changes a toggle.
    static var policy = Policy()

    /// Sync the static `policy` from AppDefaults. Called once at
    /// `applicationDidFinishLaunching` so the user's saved
    /// toggles are in effect from the first shoot load. Each
    /// Settings `.onChange` handler also updates the corresponding
    /// field directly — this is the cold-start path only.
    static func reloadPolicyFromDefaults() {
        let d = AppDefaults.shared
        policy.cacheExifSummary  = d.object(forKey: SettingsKey.cacheExifSummary)  as? Bool ?? true
        policy.cacheAFData       = d.object(forKey: SettingsKey.cacheAFData)       as? Bool ?? true
        policy.cacheSequence     = d.object(forKey: SettingsKey.cacheSequence)     as? Bool ?? true
        policy.cacheThumbnail    = d.object(forKey: SettingsKey.cacheThumbnail)    as? Bool ?? true
        let gb = d.object(forKey: SettingsKey.indexerCacheMaxSizeGB) as? Int
            ?? SettingsKey.Defaults.indexerCacheMaxSizeGB
        policy.maxTotalBytes = Int64(gb) * 1024 * 1024 * 1024
    }

    // MARK: - Payload types

    /// Bump on any breaking schema change (field type changes,
    /// removed fields, etc.). Decoders see the bump and treat
    /// the entire file as a miss → full re-index.
    nonisolated static let currentSchemaVersion = 1

    struct Payload: Codable {
        var version: Int
        var shootFolderPath: String
        var entries: [String: Entry]

        static func empty(for url: URL) -> Payload {
            Payload(version: currentSchemaVersion,
                    shootFolderPath: url.standardizedFileURL.path,
                    entries: [:])
        }
    }

    struct Entry: Codable {
        var fingerprint: Fingerprint
        var exif: ExifSummary?
        var afData: ExifToolRunner.AFData?
        var sequenceNumber: Int?
        var thumbnailJPEG: Data?
    }

    struct Fingerprint: Codable, Equatable {
        var size: Int64
        var mtimeNanos: Int64
    }

    // MARK: - Per-shoot state

    let shootFolder: URL
    private var payload: Payload
    private var dirty = false

    init(shootFolder: URL) {
        self.shootFolder = shootFolder
        self.payload = Self.loadFromDisk(at: shootFolder)
            ?? .empty(for: shootFolder)
    }

    /// Empty stub for "no shoot loaded" — `ViewerState` holds
    /// one instance and replaces it on shoot switch.
    static let noShoot = IndexerCache(shootFolder: URL(fileURLWithPath: "/"))

    // MARK: - Lookups + updates (per-shoot)

    /// Returns the cached entry for `stem` IF its on-disk
    /// fingerprint still matches the source file. Returns nil
    /// if the entry is missing, the file is missing, or the
    /// file's size/mtime no longer match (the indexer will
    /// re-run for it).
    func entry(for stem: String, sourceURL: URL) -> Entry? {
        guard let cached = payload.entries[stem] else { return nil }
        guard let now = try? Self.fingerprint(of: sourceURL) else { return nil }
        return cached.fingerprint == now ? cached : nil
    }

    /// Merge new indexer outputs into the in-memory cache. Only
    /// the fields the policy enables get stored — others stay
    /// nil. Caller passes only what they have; pre-existing
    /// fields on the entry (e.g. a basic-EXIF result from a
    /// previous batch) are preserved.
    func updateEntry(
        stem: String,
        sourceURL: URL,
        exif: ExifSummary? = nil,
        afData: ExifToolRunner.AFData? = nil,
        sequenceNumber: Int? = nil,
        thumbnailJPEG: Data? = nil
    ) {
        guard let fp = try? Self.fingerprint(of: sourceURL) else { return }
        var entry = payload.entries[stem]
            ?? Entry(fingerprint: fp)
        // If the file changed under us between read and update,
        // bump the fingerprint and treat the entry as fresh.
        if entry.fingerprint != fp {
            entry = Entry(fingerprint: fp)
        }
        let p = Self.policy
        if let exif, p.cacheExifSummary           { entry.exif = exif }
        if let afData, p.cacheAFData              { entry.afData = afData }
        if let sequenceNumber, p.cacheSequence    { entry.sequenceNumber = sequenceNumber }
        if let thumbnailJPEG, p.cacheThumbnail    { entry.thumbnailJPEG = thumbnailJPEG }
        payload.entries[stem] = entry
        dirty = true
    }

    /// Persist the in-memory payload to disk. No-op if nothing
    /// has changed since the last flush. PropertyListEncoder
    /// runs on a detached utility task so the main thread never
    /// blocks on encoding a multi-MB blob.
    func flush() async {
        guard dirty else { return }
        let snapshot = payload
        let url = Self.cacheURL(for: shootFolder)
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)
                // Atomic write via tmp + rename — partial files
                // can never confuse the next launch.
                let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
                try data.write(to: tmp, options: .atomic)
                _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
                // Touch mtime so GC's LRU ordering reflects
                // recent use.
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: url.path)
            } catch {
                Log.app.error("IndexerCache flush failed: \(String(describing: error), privacy: .public)")
            }
        }.value
        dirty = false
        Self.gcIfNeeded()
    }

    /// Final flush + clear in-memory state. Called from
    /// `closeShoot`.
    func close() async {
        await flush()
        payload = .empty(for: shootFolder)
        dirty = false
    }

    /// How many entries are currently in the cache (regardless
    /// of validity). Used by the indexer popover.
    var entryCount: Int { payload.entries.count }

    // MARK: - Disk path resolution

    /// `~/Library/Caches/PhotoX/IndexerCache/`
    static var rootDirectory: URL {
        URL.cachesDirectory
            .appendingPathComponent("PhotoX/IndexerCache")
    }

    /// Cache file URL for a given shoot folder. Stable: same
    /// folder path → same SHA256 → same filename.
    static func cacheURL(for shootFolder: URL) -> URL {
        let path = shootFolder.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return rootDirectory.appendingPathComponent("\(hex).plist")
    }

    /// Size on disk of the shoot's cache file (0 if missing).
    static func cacheSize(for shootFolder: URL) -> Int64 {
        let url = cacheURL(for: shootFolder)
        guard let attrs = try? FileManager.default
                .attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Load (static)

    /// Read the cache file for `shootFolder` from disk and
    /// validate it. Returns nil on miss, decode error, version
    /// mismatch, or path mismatch (sanity check against SHA256
    /// collision). The caller treats nil as "start fresh".
    static func loadFromDisk(at shootFolder: URL) -> Payload? {
        let url = cacheURL(for: shootFolder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = PropertyListDecoder()
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            // Corrupt file or schema drift — drop it so the
            // next flush writes a clean one.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard payload.version == currentSchemaVersion else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard payload.shootFolderPath == shootFolder.standardizedFileURL.path else {
            // SHA256 collision (essentially impossible) or the
            // shoot folder was renamed-with-same-hash. Ignore.
            return nil
        }
        return payload
    }

    // MARK: - GC + global ops

    /// Sum of all `.plist` sizes under the cache root.
    static func totalSize() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for url in urls where url.pathExtension == "plist" {
            if let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(sz)
            }
        }
        return total
    }

    /// LRU GC: walk the cache directory, sort by mtime
    /// ascending, delete oldest `.plist`s until total size is
    /// below `policy.maxTotalBytes`. Called after every flush
    /// and from the Settings "Clear cache" button.
    static func gcIfNeeded() {
        let cap = policy.maxTotalBytes
        guard cap > 0 else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let plists = urls.filter { $0.pathExtension == "plist" }
        struct Entry { let url: URL; let size: Int64; let mtime: Date }
        var entries: [Entry] = []
        var total: Int64 = 0
        for url in plists {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey,
                                                          .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate ?? .distantPast
            entries.append(Entry(url: url, size: size, mtime: mtime))
            total += size
        }
        guard total > cap else { return }
        // Oldest first (LRU).
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            if total <= cap { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Delete one shoot's cache file. Used by the popover's
    /// "Delete this shoot's cache" button.
    static func deleteCache(for shootFolder: URL) {
        try? FileManager.default.removeItem(at: cacheURL(for: shootFolder))
    }

    /// Delete EVERY shoot's cache file. Used by the popover's
    /// "Delete all caches" button + Settings.
    static func deleteAllCaches() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - Fingerprint

    /// (size, mtimeNanos) of the file at `url`. Throws if the
    /// file is missing.
    static func fingerprint(of url: URL) throws -> Fingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let mtimeNanos = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
        return Fingerprint(size: size, mtimeNanos: mtimeNanos)
    }
}
