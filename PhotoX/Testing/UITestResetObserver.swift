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
        Log.app.notice("UITestResetObserver: installed (reset + captureNow)")
    }

    private static func handleReset() {
        guard let viewerState else { return }
        // Cancel any in-flight reset so we don't run two reloads in
        // parallel. The new task subsumes the old.
        currentResetTask?.cancel()
        currentResetTask = Task { @MainActor in
            viewerState.resetForUITest()
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

    private static func handleCaptureNow() {
        guard let viewerState else { return }
        viewerState.captureLastEntryToStores()
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
