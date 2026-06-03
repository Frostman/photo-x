import XCTest

/// XCUITest coverage for behaviours added by the multi-window
/// rework that aren't already exercised by `SessionRestoreTests`
/// or the legacy single-window suite. See the Stage 8 plan for
/// the full test matrix; this file covers items 1–4 + 6–8.
///
/// The tests rely on three Stage-8-era app-side hooks gated on
/// `-photoxUITestMode YES`:
///   * `PHOTOX_UITEST_INITIAL_PATHS` env — `:`-separated paths the
///     first launch opens as N windows.
///   * `dev.frostman.PhotoX.uitest.openInNewWindow` Darwin notify
///     + `uitest.openInNewWindow.path` defaults key — simulates
///     File → Open in New Window… / ⌥-click Open Recent without
///     having to drive NSOpenPanel.
///   * `dev.frostman.PhotoX.uitest.injectFailedXMPWrite` — puts
///     the frontmost window into "has failed XMP write" state so
///     the close / quit prompts fire deterministically without
///     racing the real `XMPWriteCoordinator` batcher.
final class MultiWindowTests: PhotoXUITestCase {

    private var fixtureA: URL!
    private var fixtureB: URL!

    // MARK: - Setup / teardown

    override func setUpWithError() throws {
        continueAfterFailure = false

        fixtureA = Self.makeTempFixtureURL()
        try FileManager.default.createDirectory(at: fixtureA, withIntermediateDirectories: true)
        try Self.cloneSampleFixture(into: fixtureA)

        fixtureB = Self.makeTempFixtureURL()
        try FileManager.default.createDirectory(at: fixtureB, withIntermediateDirectories: true)
        try Self.cloneSampleFixture(into: fixtureB)

        tempFixtureURL = fixtureA
        manifest = try Self.fingerprintFixture(at: fixtureA)

        let cacheDir = fixtureA.appendingPathComponent(".photox-indexer-cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        app = XCUIApplication()
        // Default: launch with both fixtures open. Individual
        // tests override before calling launchApp() if they need
        // a single-window starting state.
        app.launchEnvironment["PHOTOX_UITEST_INITIAL_PATHS"] =
            "\(fixtureA.path):\(fixtureB.path)"
        app.launchEnvironment["PHOTOX_TEST_CACHE_DIR"] = cacheDir.path
        // Cross-process file payload channel: the XCUITest runner
        // is sandboxed and can't write `/private/tmp`, so we use
        // the runner's own NSTemporaryDirectory and hand the path
        // to the (unsandboxed) app via launch env. App-side
        // reads the same directory through `payloadDir`.
        app.launchEnvironment["PHOTOX_UITEST_PAYLOAD_DIR"] = NSTemporaryDirectory()
        app.launchArguments = [
            "-photoxDisableSparkle", "YES",
            "-photoxUITestMode", "YES",
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

    /// Test 1 — one-window-per-shoot invariant. Open A + B, then
    /// ask to open A "in a new window" (via the test-only Darwin
    /// notify that mirrors the production dedup flow). Expect the
    /// existing A window to come forward; window count stays at 2.
    func test_dedup_focusesExistingWindow() throws {
        XCTAssertTrue(waitForWindowCount(2, timeout: 10),
                      "expected two windows after initial launch")
        try postOpenInNewWindowAndWait(path: fixtureA.path)
        // The core invariant: dedup hit must NOT spawn a third
        // window. (Asserting *which* of the two windows is "key"
        // after dedup isn't reliable via XCUITest — the OS-level
        // key-window state isn't surfaced through `XCUIElement` in
        // a stable way. The window count is the load-bearing
        // assertion.)
        XCTAssertTrue(waitForWindowCount(2, timeout: 3),
                      "dedup hit must NOT spawn a third window")
        // Both windows are still present and titled correctly.
        let titles = currentWindowTitles()
        XCTAssertTrue(titles.contains { $0.contains(fixtureA.lastPathComponent) },
                      "fixtureA window missing after dedup: \(titles)")
        XCTAssertTrue(titles.contains { $0.contains(fixtureB.lastPathComponent) },
                      "fixtureB window missing after dedup: \(titles)")
    }

    /// Test 7 — open a brand-new shoot in a brand-new window via
    /// the same Darwin notify path. Starts with ONE window
    /// (fixtureA) so we can assert the spawn.
    func test_openInNewWindow_loadsSecondShoot() throws {
        // Re-launch with a single initial path so we have a
        // clean "one window" starting state.
        app.terminate()
        app.launchEnvironment["PHOTOX_UITEST_INITIAL_PATHS"] = fixtureA.path
        app.launch()
        Self.promoteToKey(app)

        XCTAssertTrue(waitForWindowCount(1, timeout: 10),
                      "expected one window after single-fixture launch")
        try postOpenInNewWindowAndWait(path: fixtureB.path)
        XCTAssertTrue(waitForWindowCount(2, timeout: 5),
                      "fixtureB should spawn a second window")
        let titles = currentWindowTitles()
        XCTAssertTrue(titles.contains { $0.contains(fixtureA.lastPathComponent) },
                      "fixtureA window missing: \(titles)")
        XCTAssertTrue(titles.contains { $0.contains(fixtureB.lastPathComponent) },
                      "fixtureB window missing: \(titles)")
    }

    /// Test 8 — same dedup behaviour as Test 1, but reached via
    /// the same notify-driven path that simulates the in-window
    /// Open Recent ⌥-click. Two windows already open, asking for
    /// the FIRST one again must still leave us at two windows.
    func test_recentOptClick_opensInNewWindow_withDedup() throws {
        XCTAssertTrue(waitForWindowCount(2, timeout: 10),
                      "expected two windows after initial launch")
        // Pretend the user ⌥-clicked Recent A: same code path as
        // openInNewWindow + dedup.
        try postOpenInNewWindowAndWait(path: fixtureA.path)
        XCTAssertTrue(waitForWindowCount(2, timeout: 3),
                      "⌥-click on already-open Recent must not spawn another window")
    }

    /// Test 2 — the NSEvent local monitor that drives arrow-key
    /// nav is gated to the key window. Open both, press ↓ then →
    /// while window A is key; only A's pill index should advance.
    func test_keyMonitor_drivesOnlyKeyWindow() throws {
        XCTAssertTrue(waitForWindowCount(2, timeout: 10), "two windows expected")

        // Wait for both shoots to finish loading.
        try waitForShootLoadedInAllWindows(timeout: 15)

        // Sanity: both windows start at pair 1.
        XCTAssertEqual(pillIndex(forWindowTitleContains: fixtureA.lastPathComponent), 1,
                       "windowA didn't start at index 1")
        XCTAssertEqual(pillIndex(forWindowTitleContains: fixtureB.lastPathComponent), 1,
                       "windowB didn't start at index 1")

        // Deterministically promote A to keyWindow via the
        // test-only Darwin hook. XCUITest's `click()` on a
        // non-key SwiftUI window doesn't reliably make it key —
        // observed during this test's earlier iterations.
        try postMakeWindowKeyAndWait(path: fixtureA.path)
        // makeKeyAndOrderFront returns immediately but macOS finishes
        // promoting the window async — the AppKit "key window" state
        // update lands on the next runloop tick or two. Without this
        // settle the test passed in isolation but flaked in the full
        // suite (the arrow event raced the promotion, both monitors
        // fired, both windows advanced).
        usleep(500_000)

        // Press right arrow once. Only A should advance, because
        // the app's local key monitor is gated on
        // `NSApp.keyWindow === viewerState.window`.
        pressKey(.rightArrow)

        // Give SwiftUI a beat to settle, then read both indices.
        // Small fixed delay is fine — both pills update on the
        // same run-loop tick the key handler fires on.
        _ = waitForPillIndexInWindow(2,
                                      titleContains: fixtureA.lastPathComponent,
                                      timeout: 3)
        XCTAssertEqual(
            pillIndex(forWindowTitleContains: fixtureA.lastPathComponent), 2,
            "windowA should have advanced to index 2")
        XCTAssertEqual(
            pillIndex(forWindowTitleContains: fixtureB.lastPathComponent), 1,
            "windowB must NOT have advanced — key-monitor gate failed")
    }

    /// Test 6 — ⌘N opens an empty window (no shoot loaded). Title
    /// is the bare app name without `: <path>`.
    func test_cmdN_opensEmptyWindow() throws {
        // Single-window start.
        app.terminate()
        app.launchEnvironment["PHOTOX_UITEST_INITIAL_PATHS"] = fixtureA.path
        app.launch()
        Self.promoteToKey(app)

        XCTAssertTrue(waitForWindowCount(1, timeout: 10), "one window expected initially")
        app.windows.firstMatch.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForWindowCount(2, timeout: 5), "⌘N should spawn a second window")

        // The new window has no shoot → title is just the app
        // display name with no `: <path>` suffix.
        // Empty-window title is the bare display name. Dev builds
        // advertise as "PhotoXDev" (per project.yml's
        // PHOTOX_DISPLAY_NAME override for the Debug config).
        let titles = currentWindowTitles()
        XCTAssertTrue(titles.contains("PhotoXDev"),
                      "empty window title \"PhotoXDev\" not found in \(titles)")
        XCTAssertTrue(titles.contains { $0.contains(fixtureA.lastPathComponent) },
                      "fixtureA window should still be present: \(titles)")
    }

    /// Test 3 — ⌘W on a window with unsaved/failed XMP must show
    /// the "Unsaved rating changes" alert. Inject the failure
    /// state, drive ⌘W, look for the alert. Choose Stay and assert
    /// the window is still there.
    func test_cmdW_promptsOnFailedXMP() throws {
        // Single-window start so the prompt scope is unambiguous.
        app.terminate()
        app.launchEnvironment["PHOTOX_UITEST_INITIAL_PATHS"] = fixtureA.path
        app.launch()
        Self.promoteToKey(app)

        XCTAssertTrue(waitForWindowCount(1, timeout: 10), "one window expected")
        try waitForShootLoadedInAllWindows(timeout: 15)

        try postInjectFailedXMPAndWait()

        app.windows.firstMatch.typeKey("w", modifierFlags: .command)

        // The alert is modal; XCUIApplication exposes it via .dialogs.
        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5),
                      "expected an 'Unsaved rating changes' alert on ⌘W")
        XCTAssertTrue(alert.staticTexts["Unsaved rating changes"].exists,
                      "alert title should be 'Unsaved rating changes'")

        // Pick Stay — window must remain.
        alert.buttons["Stay"].click()
        XCTAssertTrue(waitForWindowCount(1, timeout: 3),
                      "window should remain after Stay")
    }

    /// Test 4 — ⌘Q with a failed XMP write in ANY window must
    /// surface the consolidated unsaved-writes alert. Two-window
    /// setup confirms the alert walks all windows.
    func test_cmdQ_promptsOnFailedXMP_acrossWindows() throws {
        XCTAssertTrue(waitForWindowCount(2, timeout: 10), "two windows expected")
        try waitForShootLoadedInAllWindows(timeout: 15)

        // Inject into the frontmost window (whichever AppKit picks).
        try postInjectFailedXMPAndWait()

        // ⌘Q. NSApp routes through `applicationShouldTerminate`,
        // which is gated by our XMP/export check.
        app.windows.firstMatch.typeKey("q", modifierFlags: .command)

        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5),
                      "expected an unsaved-writes alert on ⌘Q")
        XCTAssertTrue(alert.staticTexts["Unsaved rating changes"].exists,
                      "alert title should be 'Unsaved rating changes'")
        // Stay → app stays running, both windows still present.
        alert.buttons["Stay"].click()
        XCTAssertTrue(waitForWindowCount(2, timeout: 3),
                      "both windows should remain after Stay")
    }

    // MARK: - Helpers

    private func waitForWindowCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count == expected { return true }
            usleep(100_000)
        }
        return app.windows.count == expected
    }

    private func currentWindowTitles() -> [String] {
        (0 ..< app.windows.count).map { app.windows.element(boundBy: $0).title }
    }

    /// NSPredicate-based lookup mirrors `SessionRestoreTests`,
    /// which reliably resolves windows by title-bar substring.
    /// Direct `boundBy(i).title.contains(...)` iteration was
    /// less reliable — `.title` on a non-key window sometimes
    /// returned an empty string in our session, even though
    /// the AX inspector showed the title set.
    private func window(titleContains substring: String) -> XCUIElement {
        app.windows.matching(
            NSPredicate(format: "title CONTAINS %@", substring)
        ).firstMatch
    }

    /// Read the `canvas.stemPill` pill's index portion (the
    /// "N/M" leading number) for the window whose title contains
    /// `substring`. Returns nil if the pill isn't there yet.
    ///
    /// XCUITest's descendant scoping under macOS SwiftUI windows
    /// is unreliable — `window.staticTexts[id]` often misses an
    /// element that `app.staticTexts[id]` finds, because the AX
    /// tree doesn't always parent the SwiftUI scene content under
    /// the AX window. We work around this by enumerating all
    /// matching pills at the app level and correlating to the
    /// target window via frame intersection.
    private func pillIndex(forWindowTitleContains substring: String) -> Int? {
        let w = window(titleContains: substring)
        guard w.exists else { return nil }
        let windowFrame = w.frame
        let pills = app.staticTexts
            .matching(identifier: "canvas.stemPill.indexLabel")
            .allElementsBoundByIndex
        for pill in pills {
            guard pill.exists else { continue }
            if windowFrame.contains(pill.frame.origin) {
                // SwiftUI `Text` surfaces its content via
                // `.value` on this macOS / SwiftUI build but
                // exposes an empty `.label` — see RelaunchTests'
                // cache-counter reader for the same fallback.
                let raw = (pill.value as? String) ?? pill.label
                let prefix = raw.prefix(while: { $0.isNumber })
                return Int(prefix)
            }
        }
        return nil
    }

    /// Spin-wait for every window's shoot to finish loading enough
    /// that its stem pill is rendered. Counts matching pills at
    /// app scope (descendant scoping is unreliable — see
    /// `pillIndex` for why) and waits until that matches the
    /// window count.
    private func waitForShootLoadedInAllWindows(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = app.windows.count
            let pills = app.staticTexts
                .matching(identifier: "canvas.stemPill.indexLabel")
                .count
            if count > 0 && pills >= count { return }
            usleep(150_000)
        }
        XCTFail("not all windows loaded a shoot within \(timeout)s")
    }

    private func waitForPillIndexInWindow(_ expected: Int,
                                            titleContains substring: String,
                                            timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pillIndex(forWindowTitleContains: substring) == expected { return true }
            usleep(100_000)
        }
        return pillIndex(forWindowTitleContains: substring) == expected
    }

    /// Wraps the `openInNewWindow` Darwin notify. Writes the path
    /// payload to `<NSTemporaryDirectory()>/openInNewWindow.path`
    /// (the runner's container-redirected tmp) and lets the app
    /// resolve that same directory from the `PHOTOX_UITEST_PAYLOAD_DIR`
    /// launch env. App is unsandboxed → can read into the
    /// runner's tmp; runner is sandboxed → can't write
    /// `/private/tmp`. The app's handler deletes the file after
    /// reading.
    private func postOpenInNewWindowAndWait(path: String,
                                              timeout: TimeInterval = 5) throws {
        let payload = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("openInNewWindow.path")
        try path.write(toFile: payload, atomically: true, encoding: .utf8)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.openInNewWindow",
            completion: "dev.frostman.PhotoX.uitest.openInNewWindowCompleted",
            timeout:    timeout)
    }

    private func postInjectFailedXMPAndWait(timeout: TimeInterval = 5) throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.injectFailedXMPWrite",
            completion: "dev.frostman.PhotoX.uitest.injectFailedXMPWriteCompleted",
            timeout:    timeout)
    }

    /// Make the window holding `path` key + frontmost. Writes
    /// the path to the shared payload directory and posts the
    /// `makeWindowKey` Darwin notify, waiting for completion.
    private func postMakeWindowKeyAndWait(path: String,
                                            timeout: TimeInterval = 5) throws {
        let payload = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("makeWindowKey.path")
        try path.write(toFile: payload, atomically: true, encoding: .utf8)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.makeWindowKey",
            completion: "dev.frostman.PhotoX.uitest.makeWindowKeyCompleted",
            timeout:    timeout)
    }
}
