import XCTest

/// XCUITest base class that launches a fresh `XCUIApplication` and
/// clones the sample fixture for EVERY test. The original PhotoX
/// E2E lifecycle.
///
/// Use this only for tests that genuinely need to observe the
/// app-launch cycle itself — relaunch-restores-last-entry, the
/// app-open counter incrementing across launches,
/// PendingReopenStore consumption, first-window behavior, etc.
/// Every other test should use `PhotoXSessionUITestCase` to avoid
/// the ~25 s per-test cold-start tax.
class PhotoXFreshLaunchUITestCase: PhotoXUITestCase {

    private var teardownShouldKeepFixture = false

    override func setUpWithError() throws {
        continueAfterFailure = false

        tempFixtureURL = Self.makeTempFixtureURL()
        try FileManager.default.createDirectory(at: tempFixtureURL,
                                                 withIntermediateDirectories: true)
        try Self.cloneSampleFixture(into: tempFixtureURL)
        manifest = try Self.fingerprintFixture(at: tempFixtureURL)

        // Per-test sandbox for the app's IndexerCache plists.
        // Lives under tempFixtureURL so the existing teardown
        // removeItem also cleans it up. Without this, e2e runs
        // would write plists into the user's real
        // ~/Library/Caches/PhotoX/IndexerCache/ and `gcIfNeeded`
        // could evict legitimate caches. The launchEnvironment
        // entry persists across the in-test `app.terminate()` +
        // `app.launch()` cycle so the cache survives the relaunch
        // — matches the production cache-survival contract that
        // `test_relaunch_servesIndexerCacheHits` asserts.
        let cacheDir = tempFixtureURL.appendingPathComponent(".photox-indexer-cache")
        try FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchEnvironment["PHOTOX_SAMPLE_DIR"] = tempFixtureURL.path
        app.launchEnvironment["PHOTOX_TEST_CACHE_DIR"] = cacheDir.path
        app.launchArguments = [
            "-photoxDisableSparkle",          "YES",
            "-photoxUITestMode",              "YES",
            // Preserve the scratch UserDefaults suite across
            // process restarts so a test can observe state the
            // previous launch persisted (e.g. RelaunchTests'
            // FavoriteShoots last-entry restore). Each test still
            // gets a fresh fixture tmpdir, so the path-keyed
            // entries don't collide across runs.
            "-photoxUITestPreserveDefaults",  "YES",
        ]
        app.launch()
        Self.promoteToKey(app)
    }

    override func tearDownWithError() throws {
        if let app, app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }

        var integrityError: Error?
        do {
            try Self.assertFixtureIntegrity(at: tempFixtureURL, against: manifest)
        } catch {
            integrityError = error
            teardownShouldKeepFixture = true
        }

        if let tempFixtureURL, !teardownShouldKeepFixture {
            try? FileManager.default.removeItem(at: tempFixtureURL)
        } else if let tempFixtureURL, teardownShouldKeepFixture {
            XCTContext.runActivity(named: "fixture kept at \(tempFixtureURL.path)") { _ in }
        }

        if let integrityError { throw integrityError }
        try super.tearDownWithError()
    }
}
