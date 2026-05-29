import Foundation

/// Single entry point that turns a folder path into a loaded shoot.
/// Shared between the in-app Open tab (`OpenStarterView.openPath`)
/// and the URL-scheme handler (`PhotoXApp.onOpenURL` → background
/// card watcher's "Open in PhotoX" notification action) so both
/// paths run through identical scan + favorite/recent-resume
/// logic. Anything they should agree on (error messaging, last-
/// viewed-entry restoration, same-shoot short-circuit) lives here.
@MainActor
enum OpenShootRouter {
    /// Scans `path`, picks the focus entry (preferring the user's
    /// last-viewed stem if this is a known favorite / recent),
    /// and hands the result to `state.loadShoot(_:focus:)`.
    ///
    /// On any failure (missing folder, no recognised pairs) sets
    /// `state.errorMessage` and returns without loading.
    ///
    /// Same-shoot short-circuit: if `path` matches the currently
    /// loaded shoot's `folderURL.path`, this returns immediately
    /// — callers should still flip the workspace mode separately
    /// (the URL-scheme handler and `OpenStarterView` both already
    /// do that, and the mode flip is what the user actually sees).
    static func load(path: String, state: ViewerState) async {
        // Skip the costly teardown + rescan when we're already
        // viewing this shoot. Callers handle the mode hop.
        if state.shoot?.folderURL.path == path { return }

        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            state.errorMessage = "Folder no longer exists: \(path)"
            return
        }
        let shoot = ShootScanner.scan(folder: url)
        guard let firstEntry = shoot.entries.first else {
            state.errorMessage = "No ARW + HIF/JPG pairs (or standalone HIF/JPG files) found in \(url.lastPathComponent)"
            return
        }
        // Restore the last-viewed entry if this path is a known
        // favorite or recent. Favorites take precedence (more
        // deliberate); both stores fall back to the first entry
        // silently if the saved stem no longer exists.
        let savedStem = FavoriteShoots.shared.lastEntry(for: path)
                     ?? RecentShoots.shared.lastEntry(for: path)
        let focus = savedStem
            .flatMap { stem in shoot.entries.first { $0.stem == stem } }
            ?? firstEntry
        await state.loadShoot(shoot, focus: focus)
    }
}
