import AppKit
import SwiftUI

/// Owns the floating "Usage Stats" window. One instance per app
/// (held by AppDelegate); a second click on the menu item re-shows
/// the existing window rather than spawning a new one. Non-modal so
/// the user can keep rating / navigating while looking at it.
///
/// Not @MainActor at the class level so AppDelegate (nonisolated)
/// can hold a non-lazy `let` reference. All AppKit-touching methods
/// are themselves @MainActor — UI work always lands on the main
/// thread.
final class StatsWindowController {
    private var window: NSWindow?

    @MainActor
    func show(metrics: UsageMetrics) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Esc dismisses the window via the hidden cancel-shortcut
        // trap inside StatsView; routed back through the
        // controller's close() so the reused-window cache stays
        // consistent with the visible state.
        let view = StatsView(metrics: metrics) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "PhotoX Usage Stats"
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func close() {
        window?.close()
        window = nil
    }
}
