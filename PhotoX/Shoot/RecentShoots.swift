import Foundation
import Observation

/// MRU list of recently-opened shoot folders. Persisted in UserDefaults so
/// the list survives app restarts. Capped at 10 entries.
@MainActor
@Observable
final class RecentShoots {
    static let shared = RecentShoots()

    private let key = "recentShoots.paths"
    private let lastEntryKey = "recentShoots.lastEntry"
    private let cap = 10
    private let defaults: UserDefaults

    private(set) var paths: [String] = []
    /// Last viewed entry stem per recent path. Stored alongside the
    /// MRU list so reopening a recent shoot can restore the focus
    /// position. Map kept separate from `paths` so existing call sites
    /// that iterate `paths` don't need to change.
    private(set) var lastEntryByPath: [String: String] = [:]

    /// `defaults` is injectable so tests can use a per-suite UserDefaults and
    /// avoid clobbering the user's real recents list. Production uses
    /// `.standard` via the shared instance.
    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
        self.paths = defaults.stringArray(forKey: key) ?? []
        self.lastEntryByPath = (defaults.dictionary(forKey: lastEntryKey)
            as? [String: String]) ?? [:]
    }

    func add(_ path: String) {
        var updated = paths.filter { $0 != path }
        updated.insert(path, at: 0)
        if updated.count > cap { updated = Array(updated.prefix(cap)) }
        // Drop last-entry entries for paths that fell off the MRU cap
        // so the map doesn't grow unboundedly.
        let kept = Set(updated)
        let prunedLastEntry = lastEntryByPath.filter { kept.contains($0.key) }
        paths = updated
        lastEntryByPath = prunedLastEntry
        defaults.set(updated, forKey: key)
        defaults.set(prunedLastEntry, forKey: lastEntryKey)
    }

    func clear() {
        paths = []
        lastEntryByPath = [:]
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: lastEntryKey)
    }

    func remove(_ path: String) {
        let next = paths.filter { $0 != path }
        guard next.count != paths.count else { return }
        paths = next
        lastEntryByPath.removeValue(forKey: path)
        defaults.set(next, forKey: key)
        defaults.set(lastEntryByPath, forKey: lastEntryKey)
    }

    /// Record the stem the user was on when they last saw this shoot.
    /// Pass nil to clear (rare — usually we just overwrite). No-op if
    /// the path isn't already in `paths` to avoid resurrecting paths
    /// the user explicitly removed.
    func setLastEntry(_ stem: String?, for path: String) {
        guard paths.contains(path) else { return }
        if let stem {
            lastEntryByPath[path] = stem
        } else {
            lastEntryByPath.removeValue(forKey: path)
        }
        defaults.set(lastEntryByPath, forKey: lastEntryKey)
    }

    func lastEntry(for path: String) -> String? {
        lastEntryByPath[path]
    }
}
