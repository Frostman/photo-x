import AppKit
import Foundation

/// E2E-test-only Darwin notification listener that rewinds
/// `ViewerState` to a fresh-launch baseline so the shared-session
/// `PhotoXSessionUITestCase` can run consecutive tests against the
/// same `XCUIApplication` instance.
///
/// Installed only when `LaunchFlags.uiTestMode` is true — for
/// production builds the type isn't referenced at all and the
/// notification name is opaque. A malicious local process posting
/// the notification at a production install would hit no observer
/// and do nothing.
///
/// Protocol:
///   1. Test posts `dev.frostman.PhotoX.uitest.reset` via
///      `CFNotificationCenterPostNotification` on the Darwin
///      notify center.
///   2. Observer runs `viewerState.resetForUITest()` then re-runs
///      the launch-time bootstrap path (`PHOTOX_SAMPLE_DIR` →
///      `loadShoot`).
///   3. Observer posts `dev.frostman.PhotoX.uitest.resetCompleted`
///      back so the test process can wait deterministically
///      instead of polling the UI.
///
/// Darwin notifications are cross-process by design — the sender
/// (the test runner) and the receiver (PhotoX) are separate
/// processes, so NotificationCenter wouldn't carry across.
@MainActor
enum UITestResetObserver {
    static let resetNotification = "dev.frostman.PhotoX.uitest.reset"
    static let resetCompletedNotification = "dev.frostman.PhotoX.uitest.resetCompleted"
    /// On receipt, capture the user's current position to
    /// FavoriteShoots/RecentShoots and synchronize UserDefaults.
    /// Workaround for `XCUIApplication.terminate()` not invoking
    /// `applicationWillTerminate` — RelaunchTests posts this
    /// before terminating so the relaunch sees a populated
    /// lastEntry to restore from.
    static let captureNowNotification = "dev.frostman.PhotoX.uitest.captureNow"
    static let captureNowCompletedNotification = "dev.frostman.PhotoX.uitest.captureNowCompleted"

    /// Test hook for the "open in new window" path (the one
    /// `FileMenuButtons.openWithPanel(inNewWindow:)` and
    /// `openRecentInNewWindow(path:)` use). The payload path is
    /// read from `<PHOTOX_UITEST_PAYLOAD_DIR>/openInNewWindow.path`,
    /// where `PHOTOX_UITEST_PAYLOAD_DIR` is set by the test at
    /// launch to its own `NSTemporaryDirectory()`. The XCUITest
    /// runner is sandboxed (can't write `/private/tmp`) but the
    /// (unsandboxed) app can read into the runner's container.
    static let openInNewWindowNotification = "dev.frostman.PhotoX.uitest.openInNewWindow"
    static let openInNewWindowCompletedNotification = "dev.frostman.PhotoX.uitest.openInNewWindowCompleted"
    static let openInNewWindowPayloadBasename = "openInNewWindow.path"

    /// Resolve the payload directory the test side set at launch,
    /// or nil if the env var isn't present (production launches).
    private static var payloadDir: URL? {
        guard let raw = ProcessInfo.processInfo.environment["PHOTOX_UITEST_PAYLOAD_DIR"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw)
    }

    /// Test hook for the unsaved-XMP guard surfaces (⌘W
    /// `windowShouldClose` and ⌘Q `applicationShouldTerminate`).
    /// Appends a sentinel `FailedWrite` to the frontmost
    /// window's `failedXMPWrites` so the close / quit prompt
    /// fires deterministically without needing to race a real
    /// write coordinator batch.
    static let injectFailedXMPNotification = "dev.frostman.PhotoX.uitest.injectFailedXMPWrite"
    static let injectFailedXMPCompletedNotification = "dev.frostman.PhotoX.uitest.injectFailedXMPWriteCompleted"

    /// Test hook for "make THIS shoot's window key". Reads the
    /// shoot path from `<PHOTOX_UITEST_PAYLOAD_DIR>/makeWindowKey.path`
    /// and calls `makeKeyAndOrderFront` on the matching window.
    /// Used by `MultiWindowTests.test_keyMonitor_drivesOnlyKeyWindow`
    /// to deterministically pick which window the next arrow-key
    /// event lands on — XCUITest's `XCUIElement.click()` on a
    /// non-key window doesn't reliably promote it to key in our
    /// SwiftUI WindowGroup setup.
    static let makeWindowKeyNotification = "dev.frostman.PhotoX.uitest.makeWindowKey"
    static let makeWindowKeyCompletedNotification = "dev.frostman.PhotoX.uitest.makeWindowKeyCompleted"
    static let makeWindowKeyPayloadBasename = "makeWindowKey.path"

    /// Holds the in-flight reset task so back-to-back postings
    /// don't pile up overlapping reloads. The test side waits for
    /// the completion sentinel before posting the next reset, so
    /// in practice this is just defensive.
    private static var currentResetTask: Task<Void, Never>?
    private static weak var viewerState: ViewerState?

    /// Install once at launch from `PhotoXApp.applicationDidFinishLaunching`.
    /// No-op if called more than once.
    static func install(viewerState: ViewerState) {
        guard self.viewerState == nil else { return }
        self.viewerState = viewerState

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = resetNotification as CFString
        // Bridge: CFNotificationCenter callbacks are C functions.
        // Route into a static Swift entry point that MainActor-hops
        // and calls into the captured ViewerState.
        CFNotificationCenterAddObserver(
            center,
            // Use a fixed sentinel pointer for the observer — there's
            // exactly one observer per process for this notification.
            UnsafeRawPointer(bitPattern: 0xDEADBEEF),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleReset()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
        let captureName = captureNowNotification as CFString
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xDEADCAFE),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleCaptureNow()
                }
            },
            captureName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1001),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleOpenInNewWindow()
                }
            },
            openInNewWindowNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1002),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleInjectFailedXMPWrite()
                }
            },
            injectFailedXMPNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1003),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleMakeWindowKey()
                }
            },
            makeWindowKeyNotification as CFString,
            nil,
            .deliverImmediately
        )
        Log.app.notice("UITestResetObserver: installed (reset + captureNow + openInNewWindow + injectFailedXMPWrite + makeWindowKey)")
    }

    private static func handleReset() {
        guard let viewerState else { return }
        // Cancel any in-flight reset so we don't run two reloads in
        // parallel. The new task subsumes the old.
        currentResetTask?.cancel()
        currentResetTask = Task { @MainActor in
            await viewerState.resetForUITest()
            // Re-bootstrap from PHOTOX_SAMPLE_DIR. Deliberately NOT
            // the launch-path's savedStem-first lookup: the
            // previous test's `captureLastEntryToStores` (called
            // by `closeShoot`) populates FavoriteShoots /
            // RecentShoots for this fixture path, so honouring
            // it would land each test on the entry the previous
            // test ended on. Tests that DO want last-entry
            // restoration should use PhotoXFreshLaunchUITestCase
            // and the real launch path.
            if let (shoot, firstFocus) = SamplePathProvider.resolveShoot() {
                await viewerState.loadShoot(shoot, focus: firstFocus)
            }
            postCompletionSentinel()
        }
    }

    /// Test-only "open in new window" entry point. Reads the
    /// payload path from `AppDefaults` (since Darwin notifications
    /// can't carry data), then routes through the same dedup-first
    /// flow that the user-facing menu / Recent ⌥-click uses.
    /// Always posts the completion sentinel so the test side can
    /// proceed deterministically.
    private static func handleOpenInNewWindow() {
        defer { postSentinel(openInNewWindowCompletedNotification) }
        guard let dir = payloadDir else {
            Log.app.warning("UITestResetObserver: openInNewWindow with no PHOTOX_UITEST_PAYLOAD_DIR")
            return
        }
        let payload = dir.appendingPathComponent(openInNewWindowPayloadBasename)
        let raw = (try? String(contentsOf: payload, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: payload)
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            Log.app.warning("UITestResetObserver: openInNewWindow with empty path (file=\(payload.path, privacy: .public))")
            return
        }
        // Dedup first — mirror `FileMenuButtons.openRecentInNewWindow(path:)`.
        if let existing = WindowRegistry.shared.window(forShootPath: path) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let state = WindowRegistry.shared.viewerState(for: existing) {
                NotificationCenter.default.post(
                    name: .photoxSwitchWorkspace,
                    object: WorkspaceSwitchRequest(mode: .view, target: state))
            }
            return
        }
        // Otherwise stash + spawn — the new `WindowRoot.task`
        // consumes the FIFO entry and loads the path.
        WindowRegistry.shared.enqueuePendingShoot(.path(path))
        WindowRegistry.shared.spawnNewWindow?()
    }

    /// Test-only: make the window holding a specific shoot key
    /// + frontmost. Reads the target path from
    /// `<PHOTOX_UITEST_PAYLOAD_DIR>/makeWindowKey.path`. Used by
    /// `test_keyMonitor_drivesOnlyKeyWindow` so we don't have to
    /// rely on XCUITest's click-to-focus heuristics.
    private static func handleMakeWindowKey() {
        guard let dir = payloadDir else {
            Log.app.warning("UITestResetObserver: makeWindowKey with no PHOTOX_UITEST_PAYLOAD_DIR")
            postSentinel(makeWindowKeyCompletedNotification)
            return
        }
        let payload = dir.appendingPathComponent(makeWindowKeyPayloadBasename)
        let raw = (try? String(contentsOf: payload, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: payload)
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            Log.app.warning("UITestResetObserver: makeWindowKey with empty path")
            postSentinel(makeWindowKeyCompletedNotification)
            return
        }
        guard let window = WindowRegistry.shared.window(forShootPath: path) else {
            Log.app.warning("UITestResetObserver: makeWindowKey — no window for path \(path, privacy: .public)")
            postSentinel(makeWindowKeyCompletedNotification)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // makeKeyAndOrderFront returns immediately but AppKit
        // completes the NSApp.keyWindow update on a subsequent
        // main-runloop tick. The test that immediately follows
        // (test_keyMonitor_drivesOnlyKeyWindow) needs the promotion
        // to have landed before the arrow-key event fires —
        // otherwise both windows' local monitors are armed at the
        // moment of the press and both advance. Spin the runloop
        // briefly so the sentinel only fires once NSApp.keyWindow
        // really points at us. 2 s ceiling so a stuck promotion
        // surfaces as a test failure rather than a hang.
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while NSApp.keyWindow !== window && Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
        if NSApp.keyWindow !== window {
            Log.app.warning("UITestResetObserver: makeWindowKey deadline — NSApp.keyWindow never matched target window for \(path, privacy: .public)")
        }
        postSentinel(makeWindowKeyCompletedNotification)
    }

    /// Test-only injection: appends a sentinel `FailedWrite` to
    /// the frontmost window's `failedXMPWrites` so the close /
    /// quit prompt fires deterministically. The intent value is
    /// irrelevant for the prompt — it only checks "is anything
    /// in the map?" via `hasUnsavedXMPWork`.
    private static func handleInjectFailedXMPWrite() {
        defer { postSentinel(injectFailedXMPCompletedNotification) }
        guard let state = WindowRegistry.shared.frontmostViewerState else {
            Log.app.warning("UITestResetObserver: injectFailedXMP with no frontmost state")
            return
        }
        let sentinel = XMPWriteCoordinator.FailedWrite(
            stem: "uitest-sentinel",
            intent: .setRating(5),
            attempts: 1,
            lastError: "uitest-injected failure",
            timestamp: Date())
        state.failedXMPWrites[sentinel.stem] = sentinel
    }

    private static func handleCaptureNow() {
        guard let viewerState else { return }
        viewerState.captureLastEntryToStores()
        // Mirror `AppDelegate.applicationWillTerminate`'s session
        // capture so test-driven `app.terminate()` (which doesn't
        // fire that delegate hook) leaves the same artefacts on
        // disk a real ⌘Q would. Walks every registered window's
        // ViewerState — not just the one that received the
        // captureNow notification.
        let openPaths = WindowRegistry.shared.all
            .compactMap { $0.shoot?.folderURL.path }
        OpenSessionStore.capture(openPaths)
        AppDefaults.shared.synchronize()
        postSentinel(captureNowCompletedNotification)
    }

    private static func postCompletionSentinel() {
        postSentinel(resetCompletedNotification)
    }

    private static func postSentinel(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}
