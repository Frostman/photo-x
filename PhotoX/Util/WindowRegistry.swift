import AppKit
import Foundation

/// Identifiers for SwiftUI `WindowGroup` instances. Used both by
/// the `.openWindow(id:)` environment action and by AppKit bridges
/// that spawn windows from outside SwiftUI (Dock-drop handler,
/// card-URL router).
enum WindowID {
    static let main = "main"
}

/// App-singleton registry mapping each open `NSWindow` to its
/// `ViewerState`. Multi-window support routes through here:
/// - `ShootOpener` consults the registry to enforce one-window-per-
///   shoot.
/// - `AppDelegate` walks all live ViewerStates on quit (XMP flush,
///   indexer flush) and resolves the frontmost for Sparkle's
///   shoot-URL provider and the URL-scheme handler.
///
/// Both window and viewerState refs are weak — the registry never
/// extends their lifetimes. On `NSWindow.willCloseNotification` the
/// entry self-removes so callers never have to remember to
/// deregister.
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private init() {}

    private struct Entry {
        weak var window: NSWindow?
        weak var viewerState: ViewerState?
        var closeObserver: NSObjectProtocol?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Bridge between AppKit callbacks (Dock drop, card-URL handler)
    /// and SwiftUI's `@Environment(\.openWindow)`. The App's
    /// `WindowRoot` captures the action and stores it here once;
    /// callers from outside any View context invoke
    /// `spawnNewWindow?()` to spawn a fresh `WindowGroup` instance.
    var spawnNewWindow: (() -> Void)?

    /// Shoots to claim, in order, as new windows register. Used
    /// to thread shoots through SwiftUI's window-spawn machinery —
    /// callers stash one or more entries, call `spawnNewWindow?()`
    /// once per stash, and each just-spawned `WindowRoot` consumes
    /// the FIFO head on first `.task` run.
    ///
    /// FIFO (not single-slot) so session restore on launch can
    /// enqueue N entries at once. User-driven single-spawn paths
    /// (File → Open in New Window…, Open Recent ⌥-click, Dock-drop,
    /// `CardURLRouter` rule 3) enqueue one and the next window
    /// drains one — behavior unchanged for them.
    enum PendingShoot {
        case path(String)
        case scanned(shoot: Shoot, focus: PhotoEntry)
    }
    private var pendingShoots: [PendingShoot] = []

    func enqueuePendingShoot(_ shoot: PendingShoot) {
        pendingShoots.append(shoot)
    }

    func consumePendingShoot() -> PendingShoot? {
        guard !pendingShoots.isEmpty else { return nil }
        return pendingShoots.removeFirst()
    }

    /// Register a window↔viewerState mapping. Idempotent if the same
    /// pair is re-registered (e.g. SwiftUI reruns the WindowAccessor
    /// update after a tab move). Re-registering a window with a
    /// *different* viewerState replaces the entry.
    func register(window: NSWindow, viewerState: ViewerState) {
        let id = ObjectIdentifier(window)
        if let existing = entries[id], existing.viewerState === viewerState {
            return
        }
        if let oldObserver = entries[id]?.closeObserver {
            NotificationCenter.default.removeObserver(oldObserver)
        }
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deregister(window: window)
            }
        }
        entries[id] = Entry(window: window, viewerState: viewerState, closeObserver: observer)
    }

    func deregister(window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let observer = entries[id]?.closeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        entries.removeValue(forKey: id)
    }

    // MARK: - Queries

    /// All currently registered ViewerStates (in unspecified order).
    var all: [ViewerState] {
        compact()
        return entries.values.compactMap(\.viewerState)
    }

    /// Window currently displaying the shoot at `path`, if any.
    /// Paths are compared after `standardizedFileURL` normalization
    /// so symlink aliases (`/Users/foo/x` vs `/private/var/foo/x`)
    /// dedupe correctly.
    func window(forShootPath path: String) -> NSWindow? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        compact()
        for entry in entries.values {
            guard
                let openURL = entry.viewerState?.shoot?.folderURL,
                let window = entry.window
            else { continue }
            if openURL.standardizedFileURL.path == target {
                return window
            }
        }
        return nil
    }

    /// Registered windows whose currently-loaded shoot lives inside
    /// `volume`. Used by the eject flow to find shoots that would be
    /// stranded if the volume unmounts. Paths normalized via
    /// `standardizedFileURL` so symlink aliases of the same volume
    /// dedupe correctly.
    func windows(withShootOn volume: URL) -> [(window: NSWindow, viewerState: ViewerState)] {
        let prefix = volume.standardizedFileURL.path + "/"
        compact()
        return entries.values.compactMap { entry in
            guard
                let window = entry.window,
                let state = entry.viewerState,
                let url = state.shoot?.folderURL,
                url.standardizedFileURL.path.hasPrefix(prefix)
            else { return nil }
            return (window, state)
        }
    }

    /// First registered window whose ViewerState has no shoot loaded.
    /// Used by the card-URL router to "adopt" an empty window before
    /// spawning a new one.
    func emptyWindow() -> NSWindow? {
        compact()
        return entries.values.first { entry in
            entry.window != nil && entry.viewerState?.shoot == nil
        }?.window
    }

    /// ViewerState bound to a specific window.
    func viewerState(for window: NSWindow) -> ViewerState? {
        entries[ObjectIdentifier(window)]?.viewerState
    }

    /// Best-effort "the user is looking at this one right now":
    /// AppKit's main window, falling back to the key window, then
    /// any registered window. Used by Sparkle's shoot-URL provider,
    /// `UITestResetObserver`, and AppDelegate paths that previously
    /// held a single weak ref.
    var frontmostViewerState: ViewerState? {
        compact()
        if let main = NSApp.mainWindow,
           let state = entries[ObjectIdentifier(main)]?.viewerState {
            return state
        }
        if let key = NSApp.keyWindow,
           let state = entries[ObjectIdentifier(key)]?.viewerState {
            return state
        }
        return entries.values.first?.viewerState
    }

    var frontmostWindow: NSWindow? {
        compact()
        if let main = NSApp.mainWindow, entries[ObjectIdentifier(main)] != nil {
            return main
        }
        if let key = NSApp.keyWindow, entries[ObjectIdentifier(key)] != nil {
            return key
        }
        return entries.values.first?.window
    }

    private func compact() {
        entries = entries.filter { _, entry in
            entry.window != nil && entry.viewerState != nil
        }
    }
}
