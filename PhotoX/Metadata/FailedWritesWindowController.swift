import AppKit
import SwiftUI

/// Owns the floating window that lists XMP writes the coordinator
/// couldn't persist. Non-modal so the user can keep rating while
/// looking at it. Reuses the single window instance across clicks
/// — re-shown if already open.
@MainActor
final class FailedWritesWindowController {
    private var window: NSWindow?

    func show(state: ViewerState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = FailedWritesView(state: state)
        let hosting = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Failed XMP Writes"
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
