import AppKit
import Foundation
import SwiftUI

/// App-singleton owning the single external-display window. Per-window
/// Share menus in the toolbar drive `startPresenting`/`stopPresenting`
/// against this. Only one `ViewerState` presents at a time; picking a
/// target from a different window's menu silently takes over.
///
/// Reasons the coordinator stops on its own:
/// - the bound display target disappears (observed via
///   `ExternalScreenWatcher.onTargetsRemoved`)
/// - the active presenter closes its shoot (`viewerState.shoot` becomes
///   nil, picked up via Observation tracking)
/// - the active presenter's NSWindow closes (observed via
///   `NSWindow.willCloseNotification`, NSWindow looked up through
///   `WindowRegistry`)
@MainActor
@Observable
final class PresentationCoordinator {
    static let shared: PresentationCoordinator = {
        PresentationCoordinator(watcher: .shared, windowFactory: PresentationCoordinator.defaultWindowFactory)
    }()

    /// Builds the borderless NSWindow that hosts the external display.
    /// Injectable so unit tests can supply a no-op factory; the default
    /// branches on `target.kind` between a real fullscreen window and a
    /// 100×100 offscreen window for the synthetic target.
    typealias WindowFactory = @MainActor (DisplayTarget) -> NSWindow

    /// The `ViewerState` whose current image is on the external display.
    /// Nil when nothing is presenting.
    private(set) var activePresenter: ViewerState?

    /// Display target the presentation window is bound to. Tracked so
    /// the toolbar menu can mark the active target with a checkmark and
    /// re-anchor when the user picks a different one.
    private(set) var activeTarget: DisplayTarget?

    private var tvWindow: NSWindow?
    private var windowCloseObserver: NSObjectProtocol?
    private let windowFactory: WindowFactory

    init(
        watcher: ExternalScreenWatcher,
        windowFactory: @escaping @MainActor (DisplayTarget) -> NSWindow
    ) {
        self.windowFactory = windowFactory
        watcher.onTargetsRemoved = { [weak self] removed in
            guard let self, let active = self.activeTarget else { return }
            if removed.contains(where: { $0.id == active.id }) {
                self.stopPresenting()
            }
        }
    }

    // MARK: - Queries

    func isPresenting(_ state: ViewerState) -> Bool {
        activePresenter === state
    }

    func isPresenting(_ state: ViewerState, on target: DisplayTarget) -> Bool {
        activePresenter === state && activeTarget?.id == target.id
    }

    /// Title of the window currently presenting, for the "presented by"
    /// header shown in non-presenting windows' menus. Resolved via
    /// `WindowRegistry`.
    func activePresenterWindowTitle() -> String? {
        guard let active = activePresenter else { return nil }
        for window in NSApp.windows where window.isVisible {
            if WindowRegistry.shared.viewerState(for: window) === active {
                return window.title
            }
        }
        return nil
    }

    // MARK: - Actions

    func startPresenting(_ state: ViewerState, on target: DisplayTarget) {
        // Idempotent: clicking the active target for the active state
        // is a no-op (treat as accidental).
        if activePresenter === state && activeTarget?.id == target.id { return }

        // Swap presenter and/or target. Reuse the window when possible
        // so the user sees an instant content swap rather than a close/
        // open flash.
        if let window = tvWindow {
            if activeTarget?.id != target.id {
                Self.reposition(window, for: target)
                activeTarget = target
            }
            rebindPresenter(to: state)
            return
        }

        // First-time start: build the window via the injected factory.
        let window = windowFactory(target)
        tvWindow = window
        activeTarget = target
        rebindPresenter(to: state)
        window.orderFront(nil)
    }

    func stopPresenting() {
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowCloseObserver = nil
        }
        tvWindow?.orderOut(nil)
        tvWindow = nil
        activePresenter = nil
        activeTarget = nil
    }

    // MARK: - Internals

    private func rebindPresenter(to state: ViewerState) {
        activePresenter = state
        attachWindowCloseObserver(for: state)
        // Observation tracking on `state.shoot` — re-arm after each
        // change so a later shoot-close also tears down.
        observeShootClose(of: state)
    }

    private func attachWindowCloseObserver(for state: ViewerState) {
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowCloseObserver = nil
        }
        // Find the NSWindow that owns this ViewerState via WindowRegistry.
        let target = NSApp.windows.first { window in
            WindowRegistry.shared.viewerState(for: window) === state
        }
        guard let target else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: target,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activePresenter === state else { return }
                self.stopPresenting()
            }
        }
    }

    private func observeShootClose(of state: ViewerState) {
        withObservationTracking {
            _ = state.shoot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activePresenter === state else { return }
                if state.shoot == nil {
                    self.stopPresenting()
                } else {
                    // Still has a shoot — re-arm so the next change
                    // (the eventual close) fires this branch.
                    self.observeShootClose(of: state)
                }
            }
        }
    }

    private static func reposition(_ window: NSWindow, for target: DisplayTarget) {
        switch target.kind {
        case .real:
            if let screen = target.screen {
                window.setFrame(screen.frame, display: true)
            }
        case .synthetic:
            window.setFrame(target.frame, display: true)
        }
    }

    // MARK: - Default window factory

    static let defaultWindowFactory: WindowFactory = { target in
        switch target.kind {
        case .real:
            return PresentationCoordinator.makeRealWindow(on: target.screen!)
        case .synthetic:
            return PresentationCoordinator.makeSyntheticWindow(frame: target.frame)
        }
    }

    private static func makeRealWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        configureCommon(window)
        window.setFrame(screen.frame, display: true)
        return window
    }

    private static func makeSyntheticWindow(frame: CGRect) -> NSWindow {
        // Two modes for the synthetic display:
        //
        // - E2E test mode (-photoxUITestMode): 100×100 borderless window
        //   parked at the synthetic target's declared offscreen origin.
        //   XCUITest reads the SwiftUI content via the AX tree; nothing
        //   appears on the visible screen and failure screenshots stay
        //   clean.
        //
        // - Dev mode (DEBUG + no UI-test flag): top-left quarter of the
        //   main screen at `.floating` level so the user can review the
        //   feature manually with PhotoX still active — switching focus
        //   back to PhotoX keeps the presentation window on top.
        let isUITestMode = LaunchFlags.uiTestMode
        let windowFrame: CGRect
        if isUITestMode {
            windowFrame = CGRect(x: frame.origin.x, y: frame.origin.y, width: 100, height: 100)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let quarterWidth = visible.width / 2
            let quarterHeight = visible.height / 2
            windowFrame = CGRect(
                x: visible.minX,
                y: visible.maxY - quarterHeight,   // macOS origin is bottom-left
                width: quarterWidth,
                height: quarterHeight
            )
        } else {
            windowFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        }

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureCommon(window, level: isUITestMode ? .normal : .floating)
        window.setFrame(windowFrame, display: true)
        return window
    }

    private static func configureCommon(_ window: NSWindow, level: NSWindow.Level = .normal) {
        window.identifier = NSUserInterfaceItemIdentifier("externalDisplay.window")
        window.isReleasedWhenClosed = false
        window.level = level
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.ignoresMouseEvents = true

        let root = ExternalDisplayRootView()
        window.contentView = NSHostingView(rootView: root)
    }
}
