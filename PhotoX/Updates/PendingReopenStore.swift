import Foundation

/// Tiny `AppDefaults`-backed handoff used when a Sparkle-driven
/// restart happens mid-session. Before quitting, `UpdaterController`
/// captures the currently-open shoot folder URL here; on relaunch
/// `WindowRoot.bootstrap()` consumes it and routes through the
/// existing `OpenShootRouter.load` so the user lands back on the
/// same shoot (and the same last-viewed entry within it, via the
/// favorite / recent stem-restore that already runs there).
///
/// `OpenSessionStore` is the primary session-restore mechanism
/// since multi-window landed (it captures every open window's
/// shoot at `applicationWillTerminate`). This single-URL handoff
/// is still around as a Sparkle-specific backup for the rare case
/// where `applicationWillTerminate` doesn't fire during Sparkle's
/// installer-relaunch but `updaterWillRelaunchApplication` did
/// capture the URL.
///
/// `consume()` always clears the key so a successful relaunch
/// can't replay the same target twice. No expiration — a stored
/// reopen target is honoured regardless of age (a week-old
/// half-finished install should still resume the user's shoot).
enum PendingReopenStore {
    private static let pathKey = "pendingReopen.path"

    static func set(url: URL) {
        AppDefaults.shared.set(url.path, forKey: pathKey)
    }

    /// Returns the stored URL if any, then clears.
    static func consume() -> URL? {
        let path = AppDefaults.shared.string(forKey: pathKey)
        clear()
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func clear() {
        AppDefaults.shared.removeObject(forKey: pathKey)
    }
}
