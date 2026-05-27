import XCTest

/// XCUITest base class that launches a SINGLE `XCUIApplication` and
/// clones the sample fixture ONCE per test class. Each test in the
/// class is rewound to a "fresh launch" baseline via a Darwin
/// notification handler installed in the running app.
///
/// Trade-off: avoids the ~25 s cold-start tax per test (15 tests
/// × 25 s = ~6 min) at the cost of state leakage risk between
/// tests within a class. The reset path consolidates every UI
/// surface the existing test suite mutates; if you add a new
/// stateful toggle, make sure `ViewerState.resetForUITest()`
/// covers it.
///
/// Fixture mutation: the fixture is shared across the class, so an
/// XMP write from test 1 IS visible to test 2. The reset path
/// clears the in-memory `entryXMPs`/`stemsWithXMPOnDisk` so the
/// indexer re-discovers the on-disk state, but does NOT delete the
/// XMP files themselves (matches the "no original mutation" rule
/// and XMP is the user-decision artefact). Tests that assert "this
/// entry has no XMP" must use an entry whose XMP no earlier test
/// in the class created.
///
/// Use `PhotoXFreshLaunchUITestCase` instead for tests that need a
/// fresh app process per test (relaunch / launch-cycle tests).
class PhotoXSessionUITestCase: PhotoXUITestCase {

    // MARK: shared per-class state

    private static var sharedApp: XCUIApplication?
    private static var sharedFixtureURL: URL?
    private static var sharedManifest: [String: FileFingerprint] = [:]
    private static var sharedTeardownShouldKeepFixture = false

    // MARK: class-level launch / teardown

    override class func setUp() {
        super.setUp()
        let url = PhotoXUITestCase.makeTempFixtureURL()
        do {
            try FileManager.default.createDirectory(at: url,
                                                     withIntermediateDirectories: true)
            try PhotoXUITestCase.cloneSampleFixture(into: url)
            sharedManifest = try PhotoXUITestCase.fingerprintFixture(at: url)
        } catch {
            XCTFail("class setUp: fixture clone failed: \(error)")
            return
        }
        sharedFixtureURL = url

        let app = XCUIApplication()
        app.launchEnvironment["PHOTOX_SAMPLE_DIR"] = url.path
        app.launchArguments = [
            "-photoxDisableSparkle", "YES",
            "-photoxUITestMode",     "YES",
        ]
        app.launch()
        PhotoXUITestCase.promoteToKey(app)
        sharedApp = app
    }

    override class func tearDown() {
        // Final integrity check at class-level teardown — belt and
        // braces over the per-test checks. If it fails, keep the
        // fixture for inspection.
        if let url = sharedFixtureURL {
            do {
                try PhotoXUITestCase.assertFixtureIntegrity(at: url,
                                                             against: sharedManifest)
            } catch {
                sharedTeardownShouldKeepFixture = true
                XCTContext.runActivity(named: "class tearDown fixture mutation: \(error)") { _ in }
            }
        }
        if let app = sharedApp,
           app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        if let url = sharedFixtureURL, !sharedTeardownShouldKeepFixture {
            try? FileManager.default.removeItem(at: url)
        } else if let url = sharedFixtureURL, sharedTeardownShouldKeepFixture {
            XCTContext.runActivity(named: "fixture kept at \(url.path)") { _ in }
        }
        sharedApp = nil
        sharedFixtureURL = nil
        sharedManifest = [:]
        sharedTeardownShouldKeepFixture = false
        super.tearDown()
    }

    // MARK: per-test reset + integrity check

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let app = Self.sharedApp,
              let url = Self.sharedFixtureURL else {
            XCTFail("PhotoXSessionUITestCase: class setUp didn't populate shared state")
            return
        }
        self.app = app
        self.tempFixtureURL = url
        self.manifest = Self.sharedManifest
        try resetAppState()
    }

    override func tearDownWithError() throws {
        // Per-test integrity check; the app stays alive for the
        // next test. Fail-fast surfaces XMP mutation within the
        // failing test rather than burying it in class teardown.
        do {
            try Self.assertFixtureIntegrity(at: tempFixtureURL,
                                             against: manifest)
        } catch {
            Self.sharedTeardownShouldKeepFixture = true
            throw error
        }
        try super.tearDownWithError()
    }

    // MARK: reset via Darwin notification

    /// Post the reset Darwin notification and block until the
    /// in-app observer posts the completion sentinel back.
    /// Re-promotes the window to key + waits for the shoot to
    /// reload so the next test can assume the canvas is focused
    /// on the first pair.
    private func resetAppState() throws {
        let completed = expectation(description: "uitest.resetCompleted")
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observerName = UUID().uuidString as CFString
        let completedName = "dev.frostman.PhotoX.uitest.resetCompleted" as CFString

        // Convert the C callback into a swift-callable closure via
        // an Unmanaged box. CFNotificationCenter doesn't carry
        // userInfo cross-process, so we route through a per-call
        // sentinel pointer that maps to the XCTestExpectation.
        let box = Unmanaged.passRetained(SentinelBox(expectation: completed))
        defer {
            CFNotificationCenterRemoveObserver(center,
                                                box.toOpaque(),
                                                CFNotificationName(completedName),
                                                nil)
            box.release()
        }
        CFNotificationCenterAddObserver(
            center,
            box.toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let unwrapped = Unmanaged<SentinelBox>.fromOpaque(observer).takeUnretainedValue()
                unwrapped.expectation.fulfill()
            },
            completedName,
            nil,
            .deliverImmediately
        )

        let resetName = "dev.frostman.PhotoX.uitest.reset" as CFString
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(resetName),
            nil,
            nil,
            true
        )

        wait(for: [completed], timeout: 15)
        // Re-promote the window in case the previous test left
        // focus elsewhere (e.g. opened the Stats or failed-XMP
        // window). The reset observer closes those, but
        // CFNotificationCenter delivery is async; click into the
        // canvas to anchor focus before any keystroke runs.
        Self.promoteToKey(app)
        waitForShootLoaded()
        _ = observerName    // silence unused warning if extracted later
    }

    /// Reference box so CFNotificationCenter's pointer-based
    /// observer registration can find the XCTestExpectation again.
    private class SentinelBox {
        let expectation: XCTestExpectation
        init(expectation: XCTestExpectation) {
            self.expectation = expectation
        }
    }
}
