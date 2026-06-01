import AppKit
import Foundation

/// Routes a `photox(-dev)://card?path=...` URL (posted by the
/// background card watcher) to the right window. Rules, applied
/// in order:
///
/// 1. **Match wins.** If any window already shows this shoot,
///    focus it. Protects the one-window-per-shoot invariant the
///    rest of the multi-window stack relies on.
/// 2. **Empty window adopts.** Else if any window is empty (no
///    shoot loaded), load the card into it and bring it forward —
///    avoids leaving the empty window stranded while a new
///    window opens.
/// 3. **Spawn new window.** Else stash the path in
///    `WindowRegistry.pendingShoot` and ask SwiftUI for a new
///    window. The just-spawned `WindowRoot` claims the pending
///    shoot on first `.task`.
///
/// Never replaces a busy window's shoot — so the old "cancel
/// exports?" prompt is gone.
@MainActor
enum CardURLRouter {
    static func handle(path: String) {
        // Rule 1: dedup
        if let existing = WindowRegistry.shared.window(forShootPath: path) {
            focus(window: existing)
            return
        }

        // Rule 2: empty window adopts
        if let empty = WindowRegistry.shared.emptyWindow(),
           let state = WindowRegistry.shared.viewerState(for: empty) {
            empty.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task {
                await OpenShootRouter.load(path: path, state: state)
                NotificationCenter.default.post(
                    name: .photoxSwitchWorkspace,
                    object: WorkspaceSwitchRequest(mode: .view, target: state))
            }
            return
        }

        // Rule 3: spawn new window
        WindowRegistry.shared.enqueuePendingShoot(.path(path))
        WindowRegistry.shared.spawnNewWindow?()
        // The new window's `WindowRoot.task` consumes the pending
        // shoot and loads it. `ModeWiring.onChange(of: shootMissing)`
        // auto-switches to View on the nil → non-nil transition.
    }

    private static func focus(window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let state = WindowRegistry.shared.viewerState(for: window) {
            NotificationCenter.default.post(
                name: .photoxSwitchWorkspace,
                object: WorkspaceSwitchRequest(mode: .view, target: state))
        }
    }
}
