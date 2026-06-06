import CryptoKit
import Foundation
import IndexingCore

/// On-disk cache for expensive indexer outputs, scoped per
/// shoot. Keyed by `image path + size + mtime` so a re-open of
/// the same shoot skips the indexer for files that haven't
/// changed.
///
/// Two payloads coexist in memory:
///  - `sidecarPayload`: optional, read-only, loaded from
///    `<shoot>/.photox-index.plist` (produced by the `photox`
///    CLI on the NAS). Authoritative for any stem it covers.
///  - `localPayload`: read-write, persisted to
///    `~/Library/Caches/PhotoX/IndexerCache/<sha256(path)>.plist`.
///    Backstop for stems the sidecar doesn't cover (files added
///    after the NAS run, or shoots opened without a sidecar).
///
/// `entry(for:fingerprint:)` checks sidecar first, then local;
/// `updateEntry` writes to local only — the sidecar is owned by
/// the producer and never rewritten by the macOS app.
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

    // MARK: - Type aliases (backwards compat)

    /// Per-photo entry shape — now lives in IndexingCore so the
    /// macOS app and the `photox index` CLI agree on bytes.
    typealias Entry = IndexEntry
    /// Cache key — also in IndexingCore.
    typealias Fingerprint = IndexFingerprint
    /// Library/Caches plist payload shape. Renamed internally to
    /// `LocalPayload` (to distinguish from the sidecar's
    /// `ShootSidecarIndex`), but tests reference the historical
    /// name when round-tripping through PropertyListEncoder so
    /// keep the alias visible.
    typealias Payload = LocalPayload

    // MARK: - Local payload (Library/Caches plist)

    /// Bump on any breaking schema change (field type changes,
    /// removed fields, etc.). Decoders see the bump and treat
    /// the entire file as a miss → full re-index.
    ///
    /// v2: added `Entry.thumbnailOrientation` so the hit path
    /// rotates the cached JPEG with the value the miss path
    /// used (HEIF `irot` / JPEG IFD0 tag) rather than the
    /// Exif item's TIFF orientation, which can differ or be
    /// absent — previously caused HEIF cache hits to render
    /// rotated thumbnails the wrong way up.
    ///
    /// v3: parseRegions now bails when `Sony:FocusLocation`
    /// is `0 0 0 0` (the sentinel Sony writes for "no AF
    /// info"). Existing v2 caches hold the bogus regions
    /// parsed before the filter landed; bumping forces a
    /// clean rebuild so cached AFData no longer surfaces the
    /// stray focus rectangle.
    nonisolated static let currentSchemaVersion = 3

    /// Library/Caches plist payload. Wraps the IndexingCore
    /// IndexEntry schema with macOS-side metadata (schema
    /// version + path-collision check).
    struct LocalPayload: Codable {
        var version: Int
        var shootFolderPath: String
        var entries: [String: IndexEntry]

        static func empty(for url: URL) -> LocalPayload {
            LocalPayload(version: currentSchemaVersion,
                         shootFolderPath: url.standardizedFileURL.path,
                         entries: [:])
        }
    }

    // MARK: - Hit result

    /// Where a cached entry came from. Surfaced to ViewerState so
    /// the popover can split "This open: M sidecar · K cache · L
    /// misses" instead of lumping everything as cache hits.
    enum HitSource: Sendable, Hashable {
        case sidecar
        case localCache
    }

    struct CacheHit {
        let entry: IndexEntry
        let source: HitSource

        // Forwarding accessors so callers can read `.exif`,
        // `.afData`, etc. directly without unwrapping the
        // backing IndexEntry. Matches the pre-refactor shape of
        // the cache lookup (which returned `IndexEntry?` and
        // callers accessed fields on it).
        var fingerprint: IndexFingerprint  { entry.fingerprint }
        var exif: ExifSummary?             { entry.exif }
        var afData: ExifToolRunner.AFData? { entry.afData }
        var sequenceNumber: Int?           { entry.sequenceNumber }
        var thumbnailJPEG: Data?           { entry.thumbnailJPEG }
        var thumbnailOrientation: Int?     { entry.thumbnailOrientation }
    }

    // MARK: - Per-shoot state

    let shootFolder: URL
    /// Loaded from `<shoot>/.photox-index.plist` on shoot open;
    /// read-only thereafter. nil when no sidecar exists.
    private(set) var sidecarPayload: ShootSidecarIndex?
    private var localPayload: LocalPayload
    private var dirty = false

    init(shootFolder: URL) {
        self.shootFolder = shootFolder
        self.localPayload = Self.loadLocalFromDisk(at: shootFolder)
            ?? .empty(for: shootFolder)
    }

    /// Empty stub for "no shoot loaded" — `ViewerState` holds
    /// one instance and replaces it on shoot switch.
    static let noShoot = IndexerCache(shootFolder: URL(fileURLWithPath: "/"))

    // MARK: - Sidecar hydration

    /// Hydrate the sidecar payload from
    /// `<shootFolder>/.photox-index.plist`. Off-main because a
    /// 10k-entry sidecar can be ~100 MB; reading it inline would
    /// stall the open. Call once on shoot open BEFORE the
    /// indexing pipelines start so per-entry lookups can hit it.
    /// No-op when no sidecar file exists or it's version-mismatched.
    func loadSidecar() async {
        let folder = shootFolder
        let loaded = await Task.detached(priority: .utility) {
            SidecarReader.load(at: folder)
        }.value
        sidecarPayload = loaded
    }

    /// Number of entries the sidecar covers (0 when no sidecar).
    /// Surfaced in the popover summary row.
    var sidecarEntryCount: Int { sidecarPayload?.entries.count ?? 0 }
    /// When the producer wrote the sidecar (nil when none).
    var sidecarIndexedAt: Date? { sidecarPayload?.indexedAt }
    /// Identity of the producer that wrote the sidecar (e.g.
    /// `v0.1247.0-abc123def`). Shown on hover in the popover.
    var sidecarIndexerVersion: String? { sidecarPayload?.indexerVersion }

    // MARK: - Lookups + updates (per-shoot)

    /// Returns the cached entry for `stem` if a fingerprint match
    /// hits the sidecar OR the local cache. Sidecar wins when both
    /// have an entry — the producer is the source of truth. nil
    /// signals a miss; caller's indexer re-runs for this entry.
    ///
    /// Callers pass the fingerprint they already stat'd for the
    /// file rather than us re-stat'ing here, so the same file
    /// isn't stat'd by both `entry(for:)` and the matching
    /// `updateEntry`.
    func entry(for stem: String, fingerprint: Fingerprint) -> CacheHit? {
        if let sp = sidecarPayload,
           let cached = sp.entries[stem],
           cached.fingerprint == fingerprint {
            return CacheHit(entry: cached, source: .sidecar)
        }
        if let cached = localPayload.entries[stem],
           cached.fingerprint == fingerprint {
            return CacheHit(entry: cached, source: .localCache)
        }
        return nil
    }

    /// Merge new indexer outputs into the LOCAL cache only. Only
    /// the fields the policy enables get stored — others stay
    /// nil. Caller passes only what they have; pre-existing
    /// fields on the entry (e.g. a basic-EXIF result from a
    /// previous batch) are preserved IF the fingerprint matches.
    ///
    /// No-op when the sidecar already covers this stem with a
    /// matching fingerprint — avoids duplicating data into the
    /// local plist (which would force a ~100 MB rewrite on every
    /// shoot open of an already-sidecar-covered shoot).
    func updateEntry(
        stem: String,
        fingerprint: Fingerprint,
        exif: ExifSummary? = nil,
        afData: ExifToolRunner.AFData? = nil,
        sequenceNumber: Int? = nil,
        thumbnailJPEG: Data? = nil,
        thumbnailOrientation: Int? = nil
    ) {
        if let sp = sidecarPayload,
           let cached = sp.entries[stem],
           cached.fingerprint == fingerprint {
            return
        }
        var entry = localPayload.entries[stem]
            ?? IndexEntry(fingerprint: fingerprint)
        // If the file changed since the entry was first cached,
        // bump the fingerprint and start a fresh entry — the
        // stale fields would otherwise outlive the file.
        if entry.fingerprint != fingerprint {
            entry = IndexEntry(fingerprint: fingerprint)
        }
        let p = Self.policy
        if let exif, p.cacheExifSummary           { entry.exif = exif }
        if let afData, p.cacheAFData              { entry.afData = afData }
        if let sequenceNumber, p.cacheSequence    { entry.sequenceNumber = sequenceNumber }
        if let thumbnailJPEG, p.cacheThumbnail    { entry.thumbnailJPEG = thumbnailJPEG }
        // Orientation rides along with the cached JPEG bytes
        // — no value caching it without the bytes that need it.
        if let thumbnailOrientation, p.cacheThumbnail {
            entry.thumbnailOrientation = thumbnailOrientation
        }
        localPayload.entries[stem] = entry
        dirty = true
    }

    /// Persist the LOCAL payload to disk. No-op if nothing has
    /// changed since the last flush. The sidecar is never
    /// written back — it's owned by the producer.
    /// PropertyListEncoder runs on a detached utility task so the
    /// main thread never blocks on encoding a multi-MB blob.
    func flush() async {
        guard dirty else { return }
        let snapshot = localPayload
        let url = Self.cacheURL(for: shootFolder)
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)
                // Data.write(.atomic) handles tmp + rename
                // internally and works whether or not the
                // target exists. Sets mtime to "now" natively —
                // good enough for GC's LRU ordering (resolution
                // is whatever the file system supports; in
                // practice shoots aren't opened within the same
                // second of each other, so the ordering is
                // unambiguous).
                try data.write(to: url, options: .atomic)
            } catch {
                Log.app.error("IndexerCache flush failed: \(String(describing: error), privacy: .public)")
            }
        }.value
        dirty = false
        Self.gcIfNeeded()
    }

    /// Drop cached LOCAL entries whose stem isn't in `liveStems`.
    /// Used at indexing completion to garbage-collect rows for
    /// files that have been removed from the shoot folder since
    /// the last open. Sidecar is not pruned — it's read-only and
    /// the producer owns its lifecycle.
    ///
    /// Pass the FULL set of stems currently present in the shoot;
    /// anything not in the set is removed from the local cache.
    func pruneToStems(_ liveStems: Set<String>) {
        let before = localPayload.entries.count
        localPayload.entries = localPayload.entries.filter { liveStems.contains($0.key) }
        if localPayload.entries.count != before {
            dirty = true
        }
    }

    /// Final flush + clear in-memory state. Called from
    /// `closeShoot`.
    func close() async {
        await flush()
        localPayload = .empty(for: shootFolder)
        sidecarPayload = nil
        dirty = false
    }

    /// Drop every entry from the in-memory LOCAL payload without
    /// writing it back to disk. Used by `ViewerState.reIndex()`
    /// so the upcoming pipelines see misses for every entry not
    /// covered by the sidecar, repopulate via real file reads /
    /// exiftool runs, mark the cache dirty, and the
    /// post-indexing `flush()` produces a freshly-built plist.
    /// Without this, reIndex would re-run the pipelines against
    /// an unchanged in-memory cache, every entry would be a hit,
    /// no `updateEntry` calls would land, and `flush()` would be
    /// a no-op — defeating the user's intent to rebuild.
    ///
    /// Does NOT clear the sidecar payload — re-index forces
    /// recomputation only of fields the LOCAL cache holds.
    /// To force re-read from disk for sidecar-covered files
    /// too, the user should re-run `photox index` on the NAS.
    func clearInMemory() {
        localPayload = .empty(for: shootFolder)
        dirty = false
    }

    /// How many entries are currently in the LOCAL cache
    /// (regardless of validity). Used by the indexer popover.
    var entryCount: Int { localPayload.entries.count }

    // MARK: - Disk path resolution

    /// `~/Library/Caches/PhotoX/IndexerCache/` in production.
    /// Test-overridable via `setRootDirectoryForTests(_:)` so the
    /// GC + delete-all tests don't trample the user's real cache
    /// files (which sit in the same default location).
    private static var _rootDirectoryOverride: URL?

    static var rootDirectory: URL {
        if let override = _rootDirectoryOverride { return override }
        // E2E test isolation: `PhotoXSessionUITestCase` /
        // `PhotoXFreshLaunchUITestCase` set this env var on the
        // app's launchEnvironment so test runs never touch the
        // user's real cache dir. Checked here (not in a launch
        // hook) so the redirect lands BEFORE the first IndexerCache
        // instance is constructed regardless of init order —
        // ViewerState's `private(set) var cache = IndexerCache(...)`
        // property initialiser fires before `application
        // DidFinishLaunching`, and a startup-hook override would
        // miss that initial cache.
        if let envPath = ProcessInfo.processInfo
            .environment["PHOTOX_TEST_CACHE_DIR"],
           !envPath.isEmpty {
            return URL(fileURLWithPath: envPath)
        }
        return URL.cachesDirectory
            .appendingPathComponent("PhotoX/IndexerCache")
    }

    /// Point the cache at a sandboxed directory for the duration
    /// of a test. Pass nil to restore the production default.
    /// NEVER call this in production code.
    static func setRootDirectoryForTests(_ url: URL?) {
        _rootDirectoryOverride = url
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

    // MARK: - Load local payload (static)

    /// Read the LOCAL cache file for `shootFolder` from disk and
    /// validate it. Returns nil on miss, decode error, version
    /// mismatch, or path mismatch (sanity check against SHA256
    /// collision). The caller treats nil as "start fresh".
    static func loadLocalFromDisk(at shootFolder: URL) -> LocalPayload? {
        let url = cacheURL(for: shootFolder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = PropertyListDecoder()
        guard let payload = try? decoder.decode(LocalPayload.self, from: data) else {
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
    /// file is missing. `nonisolated` so the indexing pre-pass
    /// can stat() entries off the MainActor. Forwards to the
    /// shared implementation in IndexingCore so the macOS app
    /// and the CLI compute identical fingerprints.
    nonisolated static func fingerprint(of url: URL) throws -> Fingerprint {
        try IndexingCoordinator.fingerprint(of: url)
    }
}
