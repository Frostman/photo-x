import XCTest

/// Shared "Darwin notification + completion sentinel" plumbing used
/// across every test that drives a hook installed by
/// `UITestResetObserver` (reset, captureNow, openInNewWindow,
/// injectFailedXMPWrite, makeWindowKey, …) and by passive observers
/// like `assertNotificationPosted` that only wait for a notification
/// emitted by the app.
///
/// Darwin notifications are cross-process by design — the test
/// runner and PhotoX are separate processes, so `NotificationCenter`
/// wouldn't carry across. The completion sentinel is the only way
/// the test side can deterministically know the in-app work
/// finished (UserDefaults writes flushed, state mutated, etc.) so
/// the test can proceed to assert against the next state.
///
/// Three public entry points, all `PhotoXUITestCase` extensions:
///   - `postDarwinNotification(named:)` — fire-and-forget post.
///   - `waitForDarwinNotification(named:timeout:)` — passively wait.
///   - `postDarwinNotificationAndWait(request:completion:timeout:)`
///       — the common round-trip pattern.
///
/// All three share the private `_registerDarwinObserver` workhorse
/// so the `Unmanaged<_DarwinSentinelBox>` retain/release dance lives
/// in exactly one place.
extension PhotoXUITestCase {
    /// Post `name` cross-process. Caller is responsible for any
    /// payload it expects the app to read out-of-band (e.g. via a
    /// path written to `PHOTOX_UITEST_PAYLOAD_DIR`).
    func postDarwinNotification(named name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// Wait up to `timeout` for a Darwin notification with `name` to
    /// arrive. Returns the XCTWaiter result so callers can choose
    /// how to react to a timeout (throw vs XCTFail vs ignore). Does
    /// NOT post anything — used by `assertNotificationPosted` to
    /// passively observe a notification that the app emits as a
    /// side-effect of something else (e.g. a state change).
    func waitForDarwinNotification(
        named name: String,
        timeout: TimeInterval = 5,
        description: String? = nil
    ) -> XCTWaiter.Result {
        let exp = expectation(description: description ?? "darwin.\(name)")
        let cleanup = _registerDarwinObserver(for: name, expectation: exp)
        defer { cleanup() }
        return XCTWaiter.wait(for: [exp], timeout: timeout)
    }

    /// Post `requestName`, then block up to `timeout` for the
    /// matching `completionName` sentinel. The observer is
    /// registered BEFORE the post so a fast in-process responder
    /// can't fulfill the expectation before we're listening.
    /// Throws via `wait(for:)` if the sentinel doesn't arrive.
    func postDarwinNotificationAndWait(
        request requestName: String,
        completion completionName: String,
        timeout: TimeInterval = 5
    ) throws {
        let exp = expectation(description: completionName)
        let cleanup = _registerDarwinObserver(for: completionName, expectation: exp)
        defer { cleanup() }
        postDarwinNotification(named: requestName)
        wait(for: [exp], timeout: timeout)
    }

    /// `captureNow` (used by `RelaunchTests` and `SessionRestoreTests`
    /// to simulate `applicationWillTerminate`'s persistence side
    /// effects from the test side, since `XCUIApplication.terminate()`
    /// doesn't fire that delegate).
    func postCaptureNowAndWait(timeout: TimeInterval = 5) throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.captureNow",
            completion: "dev.frostman.PhotoX.uitest.captureNowCompleted",
            timeout:    timeout
        )
    }

    /// Register a CFNotificationCenter observer for `name` that
    /// fulfills `expectation` on arrival. Returns the matching
    /// cleanup closure; callers `defer cleanup()` so the observer
    /// is removed and the Unmanaged box is released exactly once.
    /// Private because the Unmanaged retain/release contract is
    /// easy to get wrong and not something we want sprinkled
    /// across test code.
    private func _registerDarwinObserver(
        for name: String,
        expectation: XCTestExpectation
    ) -> () -> Void {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let cfName = name as CFString
        let box = Unmanaged.passRetained(_DarwinSentinelBox(expectation: expectation))
        CFNotificationCenterAddObserver(
            center,
            box.toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<_DarwinSentinelBox>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .expectation.fulfill()
            },
            cfName,
            nil,
            .deliverImmediately
        )
        return {
            CFNotificationCenterRemoveObserver(center,
                                                box.toOpaque(),
                                                CFNotificationName(cfName),
                                                nil)
            box.release()
        }
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
