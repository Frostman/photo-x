import SwiftUI
import AppKit

/// SwiftUI escape hatch that hands the host `NSWindow` to a closure
/// once the view is mounted. Backs `WindowRegistry` registration:
/// SwiftUI doesn't expose the window to a `View` directly, so we
/// drop an empty `NSView` into the hierarchy and read its `.window`
/// once layout has assigned one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Coordinator {
        var didReport = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.didReport, let window = nsView.window else { return }
        context.coordinator.didReport = true
        onWindow(window)
    }
}
