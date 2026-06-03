import XCTest

/// Shared "post a Darwin notification → wait for the app's
/// completion sentinel" plumbing. Used by every test that needs
/// to drive a test-only hook installed by `UITestResetObserver`
/// (`captureNow`, `openInNewWindow`, `injectFailedXMPWrite`, …).
///
/// Darwin notifications are cross-process by design — the test
/// runner and PhotoX are separate processes, so `NotificationCenter`
/// wouldn't carry across. The completion sentinel is the only way
/// the test side can deterministically know the in-app work
/// finished (UserDefaults writes flushed, state mutated, etc.) so
/// the test can proceed to assert against the next state.
extension PhotoXUITestCase {
    /// Post `requestName` and wait up to `timeout` for the
    /// matching `completionName` Darwin notification. Throws via
    /// `wait(for:)` if the sentinel doesn't arrive.
    func postDarwinNotificationAndWait(
        request requestName: String,
        completion completionName: String,
        timeout: TimeInterval = 5
    ) throws {
        let completed = expectation(description: completionName)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let cfCompleted = completionName as CFString
        let box = Unmanaged.passRetained(_DarwinSentinelBox(expectation: completed))
        defer {
            CFNotificationCenterRemoveObserver(center,
                                                box.toOpaque(),
                                                CFNotificationName(cfCompleted),
                                                nil)
            box.release()
        }
        CFNotificationCenterAddObserver(
            center,
            box.toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<_DarwinSentinelBox>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .expectation.fulfill()
            },
            cfCompleted,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(requestName as CFString),
            nil,
            nil,
            true
        )
        wait(for: [completed], timeout: timeout)
    }

    /// `captureNow` (used by `RelaunchTests` and
    /// `SessionRestoreTests` to simulate `applicationWillTerminate`'s
    /// persistence side effects from the test side, since
    /// `XCUIApplication.terminate()` doesn't fire that delegate).
    func postCaptureNowAndWait(timeout: TimeInterval = 5) throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.captureNow",
            completion: "dev.frostman.PhotoX.uitest.captureNowCompleted",
            timeout:    timeout
        )
    }
}

/// Reference-typed box for CFNotificationCenter observer
/// registration. `Unmanaged` retains and releases it so the
/// closure can resolve back to the `XCTestExpectation` without
/// capturing — observer registration is pointer-based.
private final class _DarwinSentinelBox {
    let expectation: XCTestExpectation
    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }
}
