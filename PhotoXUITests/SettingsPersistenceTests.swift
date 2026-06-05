import XCTest

/// XCUITest coverage for the Settings panel's persisted toggles
/// surviving a `terminate + launch` cycle.
///
/// Settings live in `AppDefaults.shared`, which under
/// `-photoxUITestMode YES` routes to the `dev.frostman.PhotoX.uitest`
/// scratch UserDefaults suite. `PhotoXFreshLaunchUITestCase` passes
/// `-photoxUITestPreserveDefaults YES` so the scratch survives the
/// in-test relaunch (without it, the second launch wipes the suite
/// and the test would always see defaults).
///
/// Each test:
/// 1. Launches with default Settings.
/// 2. Opens Settings via ⌘,.
/// 3. Clicks a Toggle (flips the persisted value).
/// 4. Closes Settings + terminates the app.
/// 5. Relaunches; asserts the new value is honoured.
final class SettingsPersistenceTests: PhotoXFreshLaunchUITestCase {

    /// Both pre- AND post-test wipe of the scratch UserDefaults
    /// keys this class touches. Pre-test guards against stale state
    /// from a prior vm-e2e invocation that crashed before tearDown;
    /// post-test cleans up for subsequent tests in the bundle. Key
    /// names mirror `SettingsKey.{sidebarVisible,autoAdvance}` in
    /// SettingsView.swift.
    override func setUpWithError() throws {
        wipeScratchKeys()
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        wipeScratchKeys()
        try super.tearDownWithError()
    }

    private func wipeScratchKeys() {
        let suite = UserDefaults(suiteName: "dev.frostman.PhotoX.uitest")
        suite?.removeObject(forKey: "settings.sidebarVisibleByDefault")
        suite?.removeObject(forKey: "settings.autoAdvanceAfterRating")
    }

    private func openSettings() {
        // The standard macOS Settings shortcut. SwiftUI's `Settings {
        // … }` scene wires this automatically; verified via
        // `app.windows["Settings"]` becoming reachable.
        pressKey(",", modifiers: .command)
        let win = settingsWindow
        XCTAssertTrue(win.waitForExistence(timeout: 3),
                      "Settings window didn't open after ⌘,")
    }

    private var settingsWindow: XCUIElement {
        // Filter by title to distinguish from the main shoot window.
        // SwiftUI's Settings scene titles the window "PhotoX
        // Settings" on macOS 14+ ("Settings" on older macOS). Match
        // either via predicate.
        app.windows.matching(NSPredicate(format: "title CONTAINS[c] 'Settings'")).firstMatch
    }

    private func closeSettings() {
        // ⌘W closes the focused window. The Settings window grabs
        // focus on open, so this lands on it.
        pressKey("w", modifiers: .command)
        // Settings window dismissal is synchronous in AppKit.
        let pred = NSPredicate(format: "exists == false")
        let exp = XCTNSPredicateExpectation(predicate: pred, object: settingsWindow)
        _ = XCTWaiter.wait(for: [exp], timeout: 2)
    }

    /// Flip the "Show sidebar by default" toggle, relaunch, assert
    /// the post-launch `state.sidebarVisible` matches the flipped
    /// value (the sidebar container appears or doesn't based on
    /// `SettingsKey.sidebarVisible` at `ViewerState.init`).
    ///
    /// Doesn't assume an initial state — `PhotoXFreshLaunchUITestCase`
    /// passes `-photoxUITestPreserveDefaults YES`, so the scratch
    /// suite carries over from any prior test in the same bundle.
    /// The persistence guarantee is "Settings flip survives a
    /// terminate + launch", verified by toggling and re-reading.
    func test_sidebarVisible_persistsAcrossLaunches() throws {
        _ = waitForShootLoaded()

        openSettings()
        let toggle = app.switches["settings.toggle.sidebarVisible"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2),
                      "sidebarVisible toggle not found in Settings")
        let before = (toggle.value as? NSNumber)?.intValue ?? -1
        toggle.click()
        let want = 1 - before
        let pred = NSPredicate(format: "value == %d", want)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 2), .completed,
                       "sidebarVisible toggle should flip to \(want) after click")
        closeSettings()

        app.terminate()
        app.launch()
        Self.promoteToKey(app)
        _ = waitForShootLoaded()

        // `sidebar.container` (ScrollView in ContentView) appears
        // when sidebarVisible == true, disappears when false.
        let container = app.scrollViews["sidebar.container"]
        if want == 1 {
            XCTAssertTrue(container.exists,
                          "sidebar should be visible after relaunch (was \(before) before flip, set to \(want))")
        } else {
            XCTAssertFalse(container.exists,
                           "sidebar should be hidden after relaunch (was \(before) before flip, set to \(want))")
        }
    }

    /// Flip the autoAdvance toggle, relaunch, assert the flipped
    /// value survived. Doesn't assume an initial state — the
    /// PreserveDefaults flag keeps the scratch suite alive across
    /// tests in the bundle, and a prior `AutoAdvanceTests` test may
    /// have already turned the toggle on. The persistence guarantee
    /// is "whatever the user sets via Settings UI survives a
    /// terminate + launch cycle", which is what we verify here.
    func test_autoAdvance_persistsAcrossLaunches() throws {
        _ = waitForShootLoaded()

        openSettings()
        let toggle = app.switches["settings.toggle.autoAdvance"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2),
                      "autoAdvance toggle not found in Settings")
        let before = (toggle.value as? NSNumber)?.intValue ?? -1
        toggle.click()
        let want = 1 - before
        let pred = NSPredicate(format: "value == %d", want)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 2), .completed,
                       "autoAdvance toggle should flip to \(want) after click")
        closeSettings()

        app.terminate()
        app.launch()
        Self.promoteToKey(app)
        _ = waitForShootLoaded()

        openSettings()
        let toggleAfter = app.switches["settings.toggle.autoAdvance"]
        XCTAssertTrue(toggleAfter.waitForExistence(timeout: 2),
                      "autoAdvance toggle missing after relaunch")
        XCTAssertEqual((toggleAfter.value as? NSNumber)?.intValue, want,
                       "autoAdvance should still be \(want) after terminate + launch (was \(before) before flip)")
    }
}
