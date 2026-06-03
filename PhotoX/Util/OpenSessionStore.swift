import Foundation

/// Persists the set of shoot folder paths that were open in
/// `WindowRegistry` at the moment `applicationWillTerminate`
/// fired, and replays them on the next launch so each window
/// reopens its previous shoot (and last-viewed entry via the
/// existing `RecentShoots.lastEntry` / `FavoriteShoots.lastEntry`
/// path inside `OpenShootRouter.load`).
///
/// Only `applicationWillTerminate` writes here — ⌘W / red-button
/// closes on a non-last window don't trigger termination, so a
/// manually-closed window is naturally absent from the registry
/// (and therefore from the captured list) by the time the user
/// quits. No expiration: a stored session is honoured no matter
/// how long ago it was saved.
///
/// Bundle-scoped via `AppDefaults.shared`, so dev (`PhotoXDev`)
/// and Release sessions persist independently and a downgrade
/// from this version simply ignores the unknown key.
enum OpenSessionStore {
    private static let pathsKey = "session.openShootPaths"

    /// Replace the persisted set with `paths`. Empty list clears
    /// the key entirely so the next launch falls through to the
    /// Sparkle / default-folder / empty-starter chain rather than
    /// hitting an empty array branch.
    static func capture(_ paths: [String]) {
        if paths.isEmpty {
            AppDefaults.shared.removeObject(forKey: pathsKey)
        } else {
            AppDefaults.shared.set(paths, forKey: pathsKey)
        }
    }

    /// Read the persisted set. Returns `[]` when nothing is
    /// stored (fresh install, upgrade from a pre-multiwindow
    /// version, or a clean-quit-with-no-shoots-open last session).
    static func restore() -> [String] {
        AppDefaults.shared.stringArray(forKey: pathsKey) ?? []
    }

    /// Wipe the key. Called from `WindowRoot.bootstrap` right
    /// after `restore()` returns a non-empty list so a crash
    /// mid-replay doesn't loop the user back into the same set
    /// on every subsequent launch.
    static func clear() {
        AppDefaults.shared.removeObject(forKey: pathsKey)
    }
}
