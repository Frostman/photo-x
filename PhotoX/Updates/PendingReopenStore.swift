import Foundation

/// Tiny `AppDefaults`-backed handoff used when a Sparkle-driven
/// restart happens mid-session. Before quitting, `UpdaterController`
/// captures the currently-open shoot folder URL here; on relaunch
/// `PhotoXApp.bootstrap()` consumes it and routes through the
/// existing `openPath` so the user lands back on the same shoot
/// (and the same last-viewed entry within it, via the favorite /
/// recent stem-restore that already runs there).
///
/// Stale entries (>10 min) are dropped on read — a relaunch the
/// next day shouldn't resurrect yesterday's restart target if the
/// install crashed or the user manually quit before relaunching.
/// `consume()` always clears the keys, fresh or stale, so a
/// successful relaunch can't replay the same target twice.
enum PendingReopenStore {
    private static let pathKey      = "pendingReopen.path"
    private static let timestampKey = "pendingReopen.timestamp"
    private static let stalenessWindow: TimeInterval = 600   // 10 min

    static func set(url: URL) {
        AppDefaults.shared.set(url.path, forKey: pathKey)
        AppDefaults.shared.set(Date().timeIntervalSince1970, forKey: timestampKey)
    }

    /// Returns the stored URL if it's still fresh, then clears.
    /// Always clears — stale or not — so the next launch starts
    /// from a clean slate.
    static func consume() -> URL? {
        let path = AppDefaults.shared.string(forKey: pathKey)
        let ts = AppDefaults.shared.double(forKey: timestampKey)
        clear()
        guard let path, !path.isEmpty,
              Date().timeIntervalSince1970 - ts < stalenessWindow
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func clear() {
        AppDefaults.shared.removeObject(forKey: pathKey)
        AppDefaults.shared.removeObject(forKey: timestampKey)
    }
}
