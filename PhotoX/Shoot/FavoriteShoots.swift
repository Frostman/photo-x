import Foundation
import Observation

/// User-curated pinned list of shoot folder paths. Independent from
/// RecentShoots — favorites stay until the user explicitly removes them,
/// while recents are MRU + capped. Persisted in UserDefaults so the list
/// survives app restarts. No cap (favorites are deliberate).
@MainActor
@Observable
final class FavoriteShoots {
    static let shared = FavoriteShoots()

    private let key = "favoriteShoots.paths"
    private let defaults: UserDefaults

    private(set) var paths: [String] = []

    /// `defaults` is injectable so tests can use a per-suite UserDefaults and
    /// avoid clobbering the user's real favorites. Production uses `.standard`
    /// via the shared instance.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.paths = defaults.stringArray(forKey: key) ?? []
    }

    func add(_ path: String) {
        guard !paths.contains(path) else { return }
        paths.insert(path, at: 0)   // newest favorite at the top
        defaults.set(paths, forKey: key)
    }

    func remove(_ path: String) {
        let next = paths.filter { $0 != path }
        guard next.count != paths.count else { return }
        paths = next
        defaults.set(next, forKey: key)
    }

    func toggle(_ path: String) {
        if contains(path) { remove(path) } else { add(path) }
    }

    func contains(_ path: String) -> Bool {
        paths.contains(path)
    }
}
