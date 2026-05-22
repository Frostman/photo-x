import AppKit
import SwiftUI

/// Owns the popup window that hosts `UpdateInstallView`. The
/// `PhotoXUserDriver` mutates the bound `UpdateInstallViewModel`
/// directly as Sparkle lifecycle methods fire — this controller
/// only handles window lifecycle + button-tap dispatch.
///
/// Non-modal floating window: the user can keep using PhotoX while
/// reading release notes / waiting for the download.
@MainActor
final class UpdateInstallWindowController {
    let model = UpdateInstallViewModel()

    /// Called when the user clicks Cancel (semantics differ by stage
    /// — see `UpdateInstallView`). Wired by `PhotoXUserDriver`.
    var onCancel: () -> Void = {}

    /// Called when the user clicks Install Update on the available
    /// stage. Wired by `PhotoXUserDriver`.
    var onInstall: () -> Void = {}

    private var window: NSWindow?
    /// Strong ref — `NSWindow.delegate` is `weak`, so without holding
    /// the delegate ourselves it deallocates the moment we assign.
    private var windowDelegate: WindowDelegate?

    func show() {
        if let window {
            Log.app.notice("update popup: re-show existing window")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Log.app.notice("update popup: creating window for v\(self.model.newVersion, privacy: .public)")
        let view = UpdateInstallView(
            model: model,
            onCancel: { [weak self] in self?.onCancel() },
            onInstall: { [weak self] in self?.onInstall() }
        )
        let hosting = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "PhotoX Update"
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        // Treat the title-bar close button as a Cancel — same effect
        // as the in-window Cancel button so Sparkle's reply chain
        // always gets a `.dismiss` (or download-cancel for later
        // stages).
        let delegate = WindowDelegate { [weak self] in self?.onCancel() }
        self.windowDelegate = delegate
        win.delegate = delegate
        win.center()
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.delegate = nil
        windowDelegate = nil
        window?.close()
        window = nil
    }

    /// Strong delegate ref so the close-button forwards to our cancel
    /// path. `NSWindow.delegate` is held weakly, so we keep this
    /// instance alive via the parent controller.
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            onClose()
            // Return false — the cancel path closes the window itself
            // after the driver has dispatched the reply block. Closing
            // here would race with that.
            return false
        }
    }
}
