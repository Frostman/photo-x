import XCTest

/// XCUITest coverage for the two auto-advance Settings toggles.
///
/// Both are read live from `AppDefaults.shared` at the time the
/// rating fires (`ViewerState.autoAdvanceAfterRating(source:)`,
/// ViewerState.swift ~line 710), so flipping the Setting takes
/// effect on the very next rating — no relaunch needed.
///
/// Each test opens the Settings panel via ⌘,, clicks the relevant
/// toggle ON, closes Settings, then performs a rating and asserts
/// the displayed stem advanced one position. FreshLaunch base so
/// every test starts from default Settings (both toggles off).
final class AutoAdvanceTests: PhotoXFreshLaunchUITestCase {

    /// The app's scratch UserDefaults suite
    /// (`dev.frostman.PhotoX.uitest`) persists across `app.terminate()`
    /// because `PhotoXFreshLaunchUITestCase` passes
    /// `-photoxUITestPreserveDefaults YES`, AND across `just vm-e2e`
    /// invocations (the VM's scratch lives in the user library).
    /// Wipe touched keys both pre- and post-test so each test starts
    /// + ends with a clean slate — including a stale state from a
    /// prior vm-e2e invocation that crashed before its own cleanup.
    /// Also wipe `sidebarVisibleByDefault` because flipping it
    /// (from a prior `SettingsPersistenceTests`) would hide the
    /// sidebar at launch and break `test_autoAdvance_sidebar_…`.
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
        suite?.removeObject(forKey: "settings.autoAdvanceAfterRating")
        suite?.removeObject(forKey: "settings.autoAdvanceAfterSidebarRating")
        suite?.removeObject(forKey: "settings.sidebarVisibleByDefault")
    }

    private var settingsWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS[c] 'Settings'")).firstMatch
    }

    private func openSettingsAndEnable(_ toggleID: String) {
        pressKey(",", modifiers: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3),
                      "Settings window didn't open after ⌘,")
        // SwiftUI Toggles inside the Settings scene render as
        // `Switch`-type AX elements (verified via the AX-tree
        // dump on a failing first attempt), not CheckBox — the
        // toggles in the StatusBar render as CheckBox, but the
        // Settings Form variant is different.
        let toggle = app.switches[toggleID]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2),
                      "toggle '\(toggleID)' missing in Settings")
        if (toggle.value as? NSNumber)?.intValue == 0 { toggle.click() }
        let onPred = NSPredicate(format: "value == 1")
        let onExp = XCTNSPredicateExpectation(predicate: onPred, object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [onExp], timeout: 2), .completed,
                       "toggle '\(toggleID)' should be ON after click")
        // Close Settings; focus returns to the main window so
        // subsequent key presses route to the canvas/handleKeyDown.
        pressKey("w", modifiers: .command)
        let closedPred = NSPredicate(format: "exists == false")
        let closedExp = XCTNSPredicateExpectation(predicate: closedPred, object: settingsWindow)
        _ = XCTWaiter.wait(for: [closedExp], timeout: 2)
    }

    /// Press "1" (set rating to 1 star) → with `autoAdvance` ON, the
    /// cursor moves to the next pair. The keyboard-rating path
    /// passes `.keyboard` to `autoAdvanceAfterRating(source:)`.
    func test_autoAdvance_keyboard_advancesAfterRating() throws {
        _ = waitForShootLoaded()
        let initial = currentStem()

        openSettingsAndEnable("settings.toggle.autoAdvance")

        pressKey("1")
        let pill = app.staticTexts["canvas.stemPill.stem"]
        let pred = NSPredicate(format: "value != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: pill)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "currentStem should advance away from '\(initial)' after keyboard rating with autoAdvance ON")
    }

    /// Click a sidebar star → with `autoAdvanceSidebar` ON, the cursor
    /// moves to the next pair. The sidebar Decisions panel's rating
    /// buttons (`decisions.star.1`…`.5`) carry the `.sidebar` source
    /// when they invoke `state.setRating(...)`.
    func test_autoAdvance_sidebar_advancesAfterStarClick() throws {
        _ = waitForShootLoaded()
        let initial = currentStem()

        openSettingsAndEnable("settings.toggle.autoAdvanceSidebar")

        let star = app.buttons["decisions.star.1"]
        XCTAssertTrue(star.waitForExistence(timeout: 3),
                      "sidebar 1-star button missing even after `B` toggle — sidebar might not be reachable")
        star.click()

        let pill = app.staticTexts["canvas.stemPill.stem"]
        let pred = NSPredicate(format: "value != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: pill)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "currentStem should advance away from '\(initial)' after sidebar star click with autoAdvanceSidebar ON")
    }
}
