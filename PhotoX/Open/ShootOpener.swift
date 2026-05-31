import AppKit
import Foundation

/// Single load chokepoint for opening a shoot in a window.
/// Enforces the hard invariant that the same shoot folder can
/// never be open in two windows simultaneously — this protects
/// XMP write safety (per-window `XMPWriteCoordinator` can't
/// coordinate across windows) and prevents duplicate decode /
/// index load.
///
/// Every shoot-load entry point (File → Open, Open Recent,
/// drag-and-drop, card-watcher URL, window restoration) funnels
/// through here. The chokepoint also normalizes paths so
/// symlink aliases of the same folder dedupe correctly.
@MainActor
enum ShootOpener {
    /// Caller's preference for *where* the shoot should land, if
    /// no existing window already shows it. Dedup wins over the
    /// requested target — if a match is found, the existing
    /// window is brought to the front and the requested target
    /// is left alone (a freshly-spawned new window stays empty).
    enum Target {
        /// Replace the shoot in the frontmost registered window.
        case replaceFrontmost
        /// Spawn a new window. Stage 1 has no menu items that
        /// produce this; Stage 2 wires `⌘⇧O` / `⌘N` / Dock-drop
        /// here.
        case newWindow
        /// Load into a caller-specified window (used by the
        /// card-URL router after it picks an empty window).
        case targetWindow(NSWindow)
    }

    enum Outcome {
        case loaded(ViewerState)
        case focusedExisting(NSWindow)
        /// The requested target couldn't be resolved (e.g.
        /// `.newWindow` requested but no spawn callback is wired
        /// yet, or no windows are registered). Stage 1 is single-
        /// window so this only fires in genuine pre-registration
        /// races.
        case noTarget
    }

    /// Open a shoot referenced by absolute folder path. Re-scans
    /// the folder via `OpenShootRouter.load`, restoring last-
    /// viewed entry from favorites / recents.
    @discardableResult
    static func open(path: String, requestedTarget: Target) async -> Outcome {
        if let existing = WindowRegistry.shared.window(forShootPath: path) {
            focus(existing)
            return .focusedExisting(existing)
        }
        guard let state = resolveTargetState(requestedTarget) else { return .noTarget }
        await OpenShootRouter.load(path: path, state: state)
        return .loaded(state)
    }

    /// Open a pre-scanned shoot (e.g. from `NSOpenPanel`, drag-
    /// and-drop, or `ShootScanner`). Avoids the re-scan that the
    /// path-based variant performs.
    @discardableResult
    static func open(shoot: Shoot, focus: PhotoEntry, requestedTarget: Target) async -> Outcome {
        if let existing = WindowRegistry.shared.window(forShootPath: shoot.folderURL.path) {
            self.focus(existing)
            return .focusedExisting(existing)
        }
        guard let state = resolveTargetState(requestedTarget) else { return .noTarget }
        await state.loadShoot(shoot, focus: focus)
        return .loaded(state)
    }

    // MARK: - Private

    private static func resolveTargetState(_ target: Target) -> ViewerState? {
        switch target {
        case .replaceFrontmost:
            return WindowRegistry.shared.frontmostViewerState
        case .targetWindow(let window):
            return WindowRegistry.shared.viewerState(for: window)
        case .newWindow:
            // Stage 2 will wire the SwiftUI `openWindow` env action
            // through here so .newWindow can spawn + register a
            // fresh window before returning.
            return nil
        }
    }

    private static func focus(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .photoxSwitchWorkspace, object: WorkspaceMode.view)
    }
}
