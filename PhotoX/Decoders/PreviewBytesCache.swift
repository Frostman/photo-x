import Foundation

/// LRU cache for the raw bytes of an entry's preview file (HIF, HEIF,
/// HEIC, JPG or JPEG). Sits in front of `PreviewDecoder` so revisiting
/// a frame during back-and-forth culling doesn't re-read it from slow
/// source media (SD card, USB stick). At ~3-15 MB per Sony A1 II HIF
/// a 2 GB budget holds ~200+ frames, dwarfing the decoded-pixel cache
/// (20 entries × ~200 MB) — different granularities for different
/// cost tiers.
///
/// Process-wide singleton (`PreviewBytesCache.shared`) so multi-window
/// PhotoX doesn't multiply the budget per window. Keys are absolute
/// file paths so entries from different shoots never collide, and
/// the LRU policy naturally trims as new content fills the budget.
actor PreviewBytesCache {
    /// Process-wide instance. Capacity is read from
    /// `SettingsKey.previewBytesCacheMB` on first access; Settings →
    /// Advanced retunes via `setByteCapacity`.
    static let shared = PreviewBytesCache(
        byteCapacity: PreviewBytesCache.capacityFromDefaults())

    /// Read the user-configured cap from `AppDefaults`. Used as the
    /// initial value for `.shared` and as the "restore to baseline"
    /// target for `MemoryPressureMonitor` after a `.warning` /
    /// `.critical` shrink.
    static func capacityFromDefaults() -> Int {
        let configured = (AppDefaults.shared.object(forKey: SettingsKey.previewBytesCacheMB) as? Int)
                         ?? SettingsKey.Defaults.previewBytesCacheMB
        return max(1, configured) * 1024 * 1024
    }

    private var entries: [String: Data] = [:]
    /// Most-recently-used at the END; eviction pops from the FRONT.
    private var order: [String] = []
    /// User-tunable via Settings → Advanced (see `setByteCapacity`).
    /// `private(set)` so callers can read but only the cache itself
    /// mutates — wrap behind setByteCapacity so eviction runs too.
    private(set) var byteCapacity: Int
    private(set) var bytesUsed: Int = 0

    init(byteCapacity: Int = 2 * 1024 * 1024 * 1024) {
        self.byteCapacity = byteCapacity
    }

    /// Resize the cache. Evicts oldest entries until `bytesUsed` is
    /// under the new cap (subject to the same "never evict the
    /// single MRU" rule as automatic eviction). Used by Settings →
    /// Advanced for live re-tuning without restart.
    func setByteCapacity(_ newCap: Int) {
        let clamped = max(1, newCap)
        guard clamped != byteCapacity else { return }
        let oldCap = byteCapacity
        let countBefore = entries.count
        byteCapacity = clamped
        evictIfNeeded()
        let evicted = countBefore - entries.count
        Log.cache.notice("preview bytes setByteCapacity \(oldCap / (1024 * 1024), privacy: .public) MB → \(self.byteCapacity / (1024 * 1024), privacy: .public) MB (evicted \(evicted, privacy: .public))")
    }

    func get(_ path: String) -> Data? {
        guard let data = entries[path] else { return nil }
        bump(path)
        return data
    }

    func set(_ data: Data, for path: String) {
        if let old = entries[path] {
            bytesUsed -= old.count
            order.removeAll { $0 == path }
        }
        entries[path] = data
        order.append(path)
        bytesUsed += data.count
        evictIfNeeded()
    }

    func clear() {
        #if DEBUG
        Log.cache.notice("preview bytes CLEAR ALL: dropped \(self.entries.count, privacy: .public) entries / \(self.bytesUsed / (1024 * 1024), privacy: .public) MB")
        #endif
        entries.removeAll()
        order.removeAll()
        bytesUsed = 0
    }

    /// Selectively drop every entry whose file path lives inside
    /// `folder`. Used by `ViewerState.closeShoot` / `loadShoot` so
    /// closing a shoot in window A reclaims its bytes immediately
    /// without disturbing window B's entries. The trailing-slash
    /// prefix prevents `/foo/bar` from incorrectly matching
    /// `/foo/barrel`.
    func clear(matching folder: URL) {
        let prefix = folder.standardizedFileURL.path + "/"
        #if DEBUG
        let countBefore = entries.count
        let bytesBefore = bytesUsed
        #endif
        var keepOrder: [String] = []
        for path in order {
            if path.hasPrefix(prefix) {
                if let removed = entries.removeValue(forKey: path) {
                    bytesUsed -= removed.count
                }
            } else {
                keepOrder.append(path)
            }
        }
        order = keepOrder
        #if DEBUG
        let dropped = countBefore - entries.count
        if dropped > 0 {
            let droppedMB = (bytesBefore - bytesUsed) / (1024 * 1024)
            // Log the abbreviated full path (not just the basename)
            // so two shoots with identical folder names in
            // different parents are unambiguous.
            let pretty = (folder.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
            Log.cache.notice("preview bytes CLEAR matching=\(pretty, privacy: .public): dropped \(dropped, privacy: .public) entries / \(droppedMB, privacy: .public) MB (kept \(self.entries.count, privacy: .public) / \(self.bytesUsed / (1024 * 1024), privacy: .public) MB)")
        }
        #endif
    }

    func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    /// Number of cached entries. Mainly for tests + diagnostics.
    var count: Int { entries.count }

    // MARK: private

    private func bump(_ path: String) {
        order.removeAll { $0 == path }
        order.append(path)
    }

    /// Evict oldest entries until we're back under budget, but never
    /// evict the single most-recently-used entry — keeping it (even if
    /// over-cap on its own) beats throwing away the just-cached frame
    /// the caller is about to decode.
    private func evictIfNeeded() {
        #if DEBUG
        var evictedNames: [String] = []
        var evictedBytes = 0
        #endif
        while bytesUsed > byteCapacity, order.count > 1 {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                bytesUsed -= removed.count
                #if DEBUG
                evictedBytes += removed.count
                evictedNames.append((oldest as NSString).lastPathComponent)
                #endif
            }
        }
        #if DEBUG
        if !evictedNames.isEmpty {
            let names = evictedNames.joined(separator: ", ")
            let mb = evictedBytes / (1024 * 1024)
            Log.cache.notice("preview bytes LRU EVICT \(evictedNames.count, privacy: .public) entries / \(mb, privacy: .public) MB: \(names, privacy: .public)")
        }
        #endif
    }
}
