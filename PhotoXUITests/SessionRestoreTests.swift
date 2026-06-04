import XCTest

/// E2E coverage for the multi-window session restore added in
/// Stage 8 — every shoot open at quit reopens on next launch.
///
/// Uses `PHOTOX_UITEST_INITIAL_PATHS` (test-only bootstrap
/// override gated by `-photoxUITestMode YES`) to seed the
/// initial window set deterministically, then drives the
/// `captureNow` Darwin notification to simulate
/// `applicationWillTerminate`'s `OpenSessionStore.capture(...)`
/// call (which `XCUIApplication.terminate()` doesn't normally
/// fire). After relaunch with no initial-paths override, the
/// restore branch is the only thing that can produce windows.
final class SessionRestoreTests: PhotoXUITestCase {

    private var fixtureA: URL!
    private var fixtureB: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        fixtureA = Self.makeTempFixtureURL()
        try FileManager.default.createDirectory(at: fixtureA, withIntermediateDirectories: true)
        try Self.cloneSampleFixture(into: fixtureA)

        fixtureB = Self.makeTempFixtureURL()
        try FileManager.default.createDirectory(at: fixtureB, withIntermediateDirectories: true)
        try Self.cloneSampleFixture(into: fixtureB)

        // Manifest only on fixture A so the base-class integrity
        // check (if anything observed it) has something to compare
        // against. Both fixtures are clean clones, so any drift in
        // either is an app-side mutation bug.
        tempFixtureURL = fixtureA
        manifest = try Self.fingerprintFixture(at: fixtureA)

        let cacheDir = fixtureA.appendingPathComponent(".photox-indexer-cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchEnvironment["PHOTOX_UITEST_INITIAL_PATHS"] =
            "\(fixtureA.path):\(fixtureB.path)"
        app.launchEnvironment["PHOTOX_TEST_CACHE_DIR"] = cacheDir.path
        app.launchArguments = [
            "-photoxDisableSparkle", "YES",
            "-photoxUITestMode", "YES",
            // Preserve the scratch UserDefaults suite across the
            // in-test `app.terminate()` + relaunch so the session
            // written by `captureNow` is visible to the new
            // process.
            "-photoxUITestPreserveDefaults", "YES",
        ]
        app.launch()
        Self.promoteToKey(app)
    }

    override func tearDownWithError() throws {
        if let app, app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        for url in [fixtureA, fixtureB].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func test_restoresTwoWindowsInOrder() throws {
        // Initial bootstrap from `PHOTOX_UITEST_INITIAL_PATHS`
        // should yield two windows.
        XCTAssertTrue(
            waitForWindowCount(2, timeout: 10),
            "expected two windows after initial launch, got \(app.windows.count)")
        let initialTitles = currentWindowTitles()
        XCTAssertTrue(initialTitles.contains { $0.contains(fixtureA.lastPathComponent) },
                      "fixtureA title missing in \(initialTitles)")
        XCTAssertTrue(initialTitles.contains { $0.contains(fixtureB.lastPathComponent) },
                      "fixtureB title missing in \(initialTitles)")

        // Persist the session, then kill the app. `captureNow` is
        // the test-mode stand-in for `applicationWillTerminate`'s
        // `OpenSessionStore.capture(...)` call — without it, the
        // SIGTERM-style `app.terminate()` would leave no on-disk
        // record for the relaunch to read.
        try postCaptureNowAndWait()
        app.terminate()

        // Relaunch WITHOUT the initial-paths override. The only
        // remaining mechanism that can produce windows is
        // `OpenSessionStore.restore()` reading the key we just
        // wrote.
        app.launchEnvironment.removeValue(forKey: "PHOTOX_UITEST_INITIAL_PATHS")
        app.launch()
        Self.promoteToKey(app)

        XCTAssertTrue(
            waitForWindowCount(2, timeout: 10),
            "expected two windows after relaunch via session restore, got \(app.windows.count)")
        let restoredTitles = currentWindowTitles()
        XCTAssertTrue(restoredTitles.contains { $0.contains(fixtureA.lastPathComponent) },
                      "fixtureA title missing after restore: \(restoredTitles)")
        XCTAssertTrue(restoredTitles.contains { $0.contains(fixtureB.lastPathComponent) },
                      "fixtureB title missing after restore: \(restoredTitles)")
    }

    func test_manualCloseExcludesFromSession() throws {
        XCTAssertTrue(waitForWindowCount(2, timeout: 10),
                      "expected two windows initially")
        // Close the SECOND window with ⌘W. Identify it by title
        // so the test doesn't depend on the order the registry
        // happens to register windows.
        let bWindow = app.windows.matching(
            NSPredicate(format: "title CONTAINS %@", fixtureB.lastPathComponent)
        ).firstMatch
        XCTAssertTrue(bWindow.exists, "couldn't find fixtureB window to close")
        bWindow.click()
        bWindow.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForWindowCount(1, timeout: 5),
                      "fixtureB window should close on ⌘W")

        try postCaptureNowAndWait()
        app.terminate()

        app.launchEnvironment.removeValue(forKey: "PHOTOX_UITEST_INITIAL_PATHS")
        app.launch()
        Self.promoteToKey(app)

        XCTAssertTrue(waitForWindowCount(1, timeout: 10),
                      "only one window should restore — the ⌘W-closed one mustn't come back")
        let titles = currentWindowTitles()
        XCTAssertTrue(titles.contains { $0.contains(fixtureA.lastPathComponent) },
                      "fixtureA window should still be there")
        XCTAssertFalse(titles.contains { $0.contains(fixtureB.lastPathComponent) },
                       "fixtureB shouldn't be in restored set; titles=\(titles)")
    }

    // MARK: - Helpers

    // waitForWindowCount and currentWindowTitles live on
    // PhotoXUITestCase (shared with MultiWindowTests).

    // `postCaptureNowAndWait` lives on `PhotoXUITestCase` via the
    // `DarwinNotifyAndWait.swift` extension (shared with
    // `RelaunchTests` and `MultiWindowTests`).
}
