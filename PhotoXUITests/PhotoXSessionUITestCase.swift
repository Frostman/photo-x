import XCTest

/// XCUITest base class that shares a SINGLE `XCUIApplication` and
/// fixture clone across **the entire test bundle** — not just per
/// class. The app launches on the first session-class test method
/// and survives until `XCTestObservation.testBundleDidFinish` fires
/// at suite end (where the integrity check + teardown also run).
///
/// Why: even with a per-class launch we paid ~25 s of cold-start
/// overhead per class. 6 session classes × 25 s = ~150 s purely on
/// launches. A bundle-singleton drops that to a single launch and
/// trims the E2E wall time substantially.
///
/// Each test rewinds via a Darwin notification handler installed in
/// the running app (`UITestResetObserver`). The reset clears
/// in-memory ViewerState + reopens the fixture; it does NOT delete
/// XMP files (matches the "no original mutation" rule). Tests that
/// assert "this entry has no XMP" must use an entry no earlier test
/// in the bundle rated.
///
/// Trade-offs vs per-class launch:
/// - Fixture XMP writes persist across ALL tests in the bundle, not
///   just within a class. Today the only writers are RatingTests'
///   two tests; the rest are read-only.
/// - A crash in any test takes out every subsequent test (the app
///   is gone). Per-class launch isolated each class from crashes.
/// - Integrity check is suite-end only, not per-test. A mid-bundle
///   mutation isn't pinpointed to a specific test, only to "some
///   test in the bundle".
///
/// Use `PhotoXFreshLaunchUITestCase` for tests that genuinely need
/// a per-test launch (relaunch lifecycle, app-open counter, etc.).
class PhotoXSessionUITestCase: PhotoXUITestCase {

    // MARK: - bundle-shared session

    // nonisolated(unsafe) because XCTestObservation's
    // testBundleDidFinish can be invoked off the main thread; the
    // XCTest harness serialises test execution so the only real
    // concurrent writer to these slots is shutdown vs first-test
    // setUp, and both paths gate on `sharedApp == nil`. macOS
    // XCTest in practice runs everything on main.
    nonisolated(unsafe) private static var sharedApp: XCUIApplication?
    nonisolated(unsafe) private static var sharedFixtureURL: URL?
    /// Per-session sandbox for the app's IndexerCache plists. Passed
    /// to the app via `PHOTOX_TEST_CACHE_DIR` env var so the running
    /// process redirects `IndexerCache.rootDirectory` here instead
    /// of `~/Library/Caches/PhotoX/IndexerCache/`. Without this,
    /// e2e runs would leak cache files into the user's real cache
    /// dir and `gcIfNeeded` could even evict legitimate caches.
    nonisolated(unsafe) private static var sharedCacheDirURL: URL?
    nonisolated(unsafe) private static var sharedManifest: [String: FileFingerprint] = [:]
    nonisolated(unsafe) private static var observerRegistered = false
    nonisolated(unsafe) private static var keepFixtureOnTeardown = false

    /// Lazily launch the app and clone the fixture on first call;
    /// no-op once `sharedApp` is populated AND still running.
    /// If a prior interleaved PhotoXFreshLaunchUITestCase test left
    /// `sharedApp.state == .notRunning` (XCUITest reuses XCUIApplication
    /// instances by bundle id, so terminating the fresh-launch app
    /// can clobber the session app's process), we fall through and
    /// relaunch with the existing fixture.
    private static func ensureSessionLaunched() {
        if let app = sharedApp,
           app.state == .runningForeground || app.state == .runningBackground {
            return
        }
        if sharedApp != nil, let url = sharedFixtureURL {
            // The shared process is gone but the fixture is still
            // there. Relaunch against it. Reuse the existing cache
            // dir so any plists written before the process died are
            // still seen by the next launch (matches the per-launch
            // cache survival contract production users rely on).
            let app = XCUIApplication()
            app.launchEnvironment["PHOTOX_SAMPLE_DIR"] = url.path
            if let cache = sharedCacheDirURL {
                app.launchEnvironment["PHOTOX_TEST_CACHE_DIR"] = cache.path
            }
            app.launchArguments = [
                "-photoxDisableSparkle", "YES",
                "-photoxUITestMode",     "YES",
            ]
            // Payload directory the app reads cross-process payloads
            // from (addExportDestination.json, makeWindowKey.path,
            // etc.). The XCUITest runner is sandboxed and can only
            // write to its own NSTemporaryDirectory.
            app.launchEnvironment["PHOTOX_UITEST_PAYLOAD_DIR"] = NSTemporaryDirectory()
            app.launch()
            PhotoXUITestCase.promoteToKey(app)
            sharedApp = app
            return
        }
        let url = PhotoXUITestCase.makeTempFixtureURL()
        let cacheDir = url.appendingPathComponent(".photox-indexer-cache")
        do {
            try FileManager.default.createDirectory(at: url,
                                                     withIntermediateDirectories: true)
            try PhotoXUITestCase.cloneSampleFixture(into: url)
            sharedManifest = try PhotoXUITestCase.fingerprintFixture(at: url)
            try FileManager.default.createDirectory(at: cacheDir,
                                                     withIntermediateDirectories: true)
        } catch {
            XCTFail("session setUp: fixture clone failed: \(error)")
            return
        }
        sharedFixtureURL = url
        sharedCacheDirURL = cacheDir

        let app = XCUIApplication()
        app.launchEnvironment["PHOTOX_SAMPLE_DIR"] = url.path
        app.launchEnvironment["PHOTOX_TEST_CACHE_DIR"] = cacheDir.path
        app.launchArguments = [
            "-photoxDisableSparkle", "YES",
            "-photoxUITestMode",     "YES",
        ]
        // See the matching comment in the relaunch branch above —
        // payload directory the app reads cross-process payloads from.
        app.launchEnvironment["PHOTOX_UITEST_PAYLOAD_DIR"] = NSTemporaryDirectory()
        app.launch()
        PhotoXUITestCase.promoteToKey(app)
        sharedApp = app

        if !observerRegistered {
            observerRegistered = true
            XCTestObservationCenter.shared.addTestObserver(SessionObserver.shared)
        }
    }

    /// Tear down the bundle session: terminate the app, run the
    /// final integrity check, delete the fixture (or keep it on
    /// failure for inspection). Called from `SessionObserver.test
    /// BundleDidFinish` once XCTest finishes the whole bundle.
    fileprivate static func shutdown() {
        if let url = sharedFixtureURL {
            do {
                try PhotoXUITestCase.assertFixtureIntegrity(at: url,
                                                             against: sharedManifest)
            } catch {
                keepFixtureOnTeardown = true
                XCTContext.runActivity(named: "suite-end fixture mutation: \(error)") { _ in }
            }
        }
        if let app = sharedApp,
           app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        if let url = sharedFixtureURL {
            if keepFixtureOnTeardown {
                XCTContext.runActivity(named: "fixture kept at \(url.path)") { _ in }
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // sharedCacheDirURL lives under sharedFixtureURL, so the
        // removeItem above already cleaned it up. Just clear the
        // slot so the next session allocates a fresh one.
        sharedApp = nil
        sharedFixtureURL = nil
        sharedCacheDirURL = nil
        sharedManifest = [:]
        keepFixtureOnTeardown = false
    }

    // MARK: - per-test reset (no launch, no integrity check)

    override func setUpWithError() throws {
        continueAfterFailure = false
        Self.ensureSessionLaunched()
        guard let app = Self.sharedApp,
              let url = Self.sharedFixtureURL else {
            XCTFail("PhotoXSessionUITestCase: session launch didn't populate shared state")
            return
        }
        self.app = app
        self.tempFixtureURL = url
        self.manifest = Self.sharedManifest
        try resetAppState()
    }

    override func tearDownWithError() throws {
        // Per-test integrity check intentionally dropped — runs
        // once at suite end via SessionObserver. The cost (SHA256
        // of ~3 GB of fixture per test) was the largest non-launch
        // overhead in the old design.
        try super.tearDownWithError()
    }

    // MARK: - reset via Darwin notification

    /// Drive the in-process `UITestResetObserver` reset hook and
    /// wait for its `resetCompleted` sentinel. 5 s is 2× the typical
    /// 2–4 s reset+reopen+index cycle — tight enough to fail fast
    /// on a hung observer, loose enough to ride out a slow indexing
    /// pass. The previous 15 s ceiling masked stuck cycles for too
    /// long.
    ///
    /// No `promoteToKey` + `waitForShootLoaded` here on purpose.
    /// Every test method's first line calls `waitForShootLoaded`
    /// (which polls the pill AND clicks the canvas to anchor
    /// focus). Doing both before the test ran cost ~2–3 s per
    /// reset × 14 resets ≈ 30–40 s of pure dead time.
    private func resetAppState() throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.reset",
            completion: "dev.frostman.PhotoX.uitest.resetCompleted",
            timeout:    5
        )
    }

    // MARK: - bundle-end observer

    private class SessionObserver: NSObject, XCTestObservation {
        nonisolated(unsafe) static let shared = SessionObserver()
        func testBundleDidFinish(_ testBundle: Bundle) {
            PhotoXSessionUITestCase.shutdown()
        }
    }
}
