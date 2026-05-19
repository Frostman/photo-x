import Foundation

/// LRU cache for raw HIF file bytes, bounded by total size. Sits in
/// front of the HEIF decoder so revisiting a frame during back-and-forth
/// culling doesn't re-read it from slow source media (SD card, USB stick).
/// At ~3-15 MB per Sony A1 II HIF a 2 GB budget holds ~200+ frames,
/// dwarfing the decoded-pixel cache (20 entries × ~200 MB) — different
/// granularities for different cost tiers.
///
/// The cache persists across shoot switches: paths are unique per shoot
/// (folder-rooted), so old entries never collide with new shoots' files
/// and the LRU policy naturally trims as a new shoot fills the budget.
actor HIFBytesCache {
    private var entries: [String: Data] = [:]
    /// Most-recently-used at the END; eviction pops from the FRONT.
    private var order: [String] = []
    let byteCapacity: Int
    private(set) var bytesUsed: Int = 0

    init(byteCapacity: Int = 2 * 1024 * 1024 * 1024) {
        self.byteCapacity = byteCapacity
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
        entries.removeAll()
        order.removeAll()
        bytesUsed = 0
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
        while bytesUsed > byteCapacity, order.count > 1 {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                bytesUsed -= removed.count
            }
        }
    }
}
