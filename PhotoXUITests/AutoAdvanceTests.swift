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

    /// Wipe the keys this class mutates both pre- AND post-test
    /// so each test starts + ends with a clean slate, regardless of
    /// what a prior test (or a prior `just vm-e2e` invocation) left
    /// behind. `sidebarVisibleByDefault` is included because flipping
    /// it (from a prior `SettingsPersistenceTests`) hides the sidebar
    /// at launch and breaks the sidebar-star-click test. See
    /// `PhotoXUITestCase.wipeScratchUserDefaults` for why scratch
    /// state survives `app.terminate()` + vm-e2e boundaries.
    private static let touchedKeys = [
        "settings.autoAdvanceAfterRating",
        "settings.autoAdvanceAfterSidebarRating",
        "settings.sidebarVisibleByDefault",
    ]

    override func setUpWithError() throws {
        Self.wipeScratchUserDefaults(keys: Self.touchedKeys)
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        Self.wipeScratchUserDefaults(keys: Self.touchedKeys)
        try super.tearDownWithError()
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
        // Belt + suspenders: the setUp's UserDefaults wipe of
        // `settings.sidebarVisibleByDefault` should leave the
        // sidebar visible at launch, but cross-process scratch sync
        // through cfprefsd has been observed to lag — verified
        // empirically by full-suite runs where the sidebar landed
        // hidden despite a clean pre-test wipe. The `B` key toggles
        // `state.sidebarVisible` at runtime (independent of the
        // persisted default), so this ensures the sidebar is
        // reachable regardless of what the cached scratch holds.
        if !app.scrollViews["sidebar.container"].exists {
            pressKey("B")
        }
        let initial = currentStem()

        openSettingsAndEnable("settings.toggle.autoAdvanceSidebar")

        let star = app.buttons["decisions.star.1"]
        XCTAssertTrue(star.waitForExistence(timeout: 3),
                      "sidebar 1-star button missing")
        star.click()

        let pill = app.staticTexts["canvas.stemPill.stem"]
        let pred = NSPredicate(format: "value != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: pill)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "currentStem should advance away from '\(initial)' after sidebar star click with autoAdvanceSidebar ON")
    }
}
