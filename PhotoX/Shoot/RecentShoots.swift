import Foundation
import Observation

/// MRU list of recently-opened shoot folders. Persisted in UserDefaults so
/// the list survives app restarts. Capped at 10 entries.
@MainActor
@Observable
final class RecentShoots {
    static let shared = RecentShoots()

    private let key = "recentShoots.paths"
    private let cap = 10
    private let defaults: UserDefaults

    private(set) var paths: [String] = []

    /// `defaults` is injectable so tests can use a per-suite UserDefaults and
    /// avoid clobbering the user's real recents list. Production uses
    /// `.standard` via the shared instance.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.paths = defaults.stringArray(forKey: key) ?? []
    }

    func add(_ path: String) {
        var updated = paths.filter { $0 != path }
        updated.insert(path, at: 0)
        if updated.count > cap { updated = Array(updated.prefix(cap)) }
        paths = updated
        defaults.set(updated, forKey: key)
    }

    func clear() {
        paths = []
        defaults.removeObject(forKey: key)
    }
}
