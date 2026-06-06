import XCTest

/// End-to-end coverage for the Present-to-Display feature:
/// Share toolbar button, popover, P keyboard shortcut, InfoBar
/// contents on the (offscreen) external display window, and
/// auto-teardown on shoot close.
///
/// The DEBUG build (which the test host runs in) auto-publishes a
/// synthetic "Fake Display 4K" target via `ExternalScreenWatcher`,
/// so we don't need a real external monitor. The synthetic target's
/// NSWindow is created 100×100 at (-10000, -10000) — XCUITest reads
/// the AX tree so its SwiftUI content (InfoBar stem + index) is
/// fully queryable despite the offscreen position.
final class PresentToDisplayE2ETests: PhotoXFreshLaunchUITestCase {

    // MARK: - toolbar button

    func test_shareButton_visible_whenShootOpen() {
        _ = waitForShootLoaded()
        let button = app.buttons["toolbar.shareToDisplay"]
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "Share button should appear once a shoot is loaded")
        XCTAssertEqual(button.value as? String, "idle",
                       "Share button starts in idle state")
    }

    func test_popover_listsFakeDisplay() {
        _ = waitForShootLoaded()
        openSharePopover()

        let row = app.buttons["share.target.synthetic.fakeDisplay"]
        XCTAssertTrue(row.waitForExistence(timeout: 2),
                      "DEBUG build should auto-list the synthetic Fake Display target")
    }

    // MARK: - presenting

    func test_pickingFakeDisplay_startsPresenting() throws {
        let total = waitForShootLoaded()
        let firstStem = try XCTUnwrap(try sortedPairStems().first)

        openSharePopover()
        coordinateClick(app.buttons["share.target.synthetic.fakeDisplay"])

        // Query InfoBar immediately — the chip auto-hides after ~3 s,
        // and intervening waits for unrelated state would push the
        // read past that window.
        let stemLabel = app.staticTexts["externalDisplay.infoBar.stem"]
        XCTAssertTrue(stemLabel.waitForExistence(timeout: 3),
                      "InfoBar stem text should be queryable on the external display")
        XCTAssertEqual(stemLabel.value as? String, firstStem,
                       "InfoBar stem must match the first pair's stem")

        let indexLabel = app.staticTexts["externalDisplay.infoBar.index"]
        XCTAssertEqual(indexLabel.value as? String, "1 of \(total)",
                       "InfoBar index should read '1 of N' for a fresh shoot")

        let button = app.buttons["toolbar.shareToDisplay"]
        let predValue = NSPredicate(format: "value == %@", "presenting")
        let exp = XCTNSPredicateExpectation(predicate: predValue, object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Share button should flip to 'presenting' after picking a target")

        let extWindow = app.windows["externalDisplay.window"]
        XCTAssertTrue(extWindow.exists,
                      "external display NSWindow should be in the AX tree")
    }

    func test_arrowNavigation_updatesInfoBar() throws {
        _ = waitForShootLoaded()
        let stems = try sortedPairStems()
        try XCTSkipIf(stems.count < 2, "fixture has fewer than 2 pairs")

        openSharePopover()
        coordinateClick(app.buttons["share.target.synthetic.fakeDisplay"])
        _ = app.staticTexts["externalDisplay.infoBar.stem"].waitForExistence(timeout: 3)

        pressKey(.rightArrow)

        let stemLabel = app.staticTexts["externalDisplay.infoBar.stem"]
        let pred = NSPredicate(format: "value == %@", stems[1])
        let exp = XCTNSPredicateExpectation(predicate: pred, object: stemLabel)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "external display stem should advance to the second pair after →")
    }

    // MARK: - keyboard
    //
    // Stop-sharing via the popover's "Stop Sharing" row and shoot-close
    // auto-stop are covered by the unit suite (PresentationCoordinatorTests).
    // The VM's main-window AX-Disabled state makes toolbar-button clicks
    // (Share, Close Folder) unreliable for follow-up actions, so those
    // behaviors stay in the unit layer. The P keyboard shortcut covers
    // the equivalent stop path end-to-end.

    func test_pKeyboard_idle_opensPopover() {
        _ = waitForShootLoaded()
        pressKey("p")

        let row = app.buttons["share.target.synthetic.fakeDisplay"]
        XCTAssertTrue(row.waitForExistence(timeout: 2),
                      "P should open the Share popover when nothing is presenting")
    }

    func test_pKeyboard_active_stops() {
        _ = waitForShootLoaded()
        openSharePopover()
        coordinateClick(app.buttons["share.target.synthetic.fakeDisplay"])
        _ = app.windows["externalDisplay.window"].waitForExistence(timeout: 3)

        pressKey("p")

        let button = app.buttons["toolbar.shareToDisplay"]
        let predIdle = NSPredicate(format: "value == %@", "idle")
        let exp = XCTNSPredicateExpectation(predicate: predIdle, object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "P while presenting should stop")
    }

    // MARK: - helpers

    /// Open the Share popover via the P keyboard shortcut. The toolbar
    /// button's `.click()` is unreliable in the VM because the
    /// test-runner-owned main window stays AX-`Disabled`, but the
    /// canvas-focused NSEvent monitor catches `P` regardless of focus
    /// state, so this path is solid.
    private func openSharePopover() {
        pressKey("p")
    }

    /// Click at the element's center coordinate. `.click()` requires
    /// `isHittable`, which is unreliable on the test-runner-owned
    /// window in the VM; coordinate clicks bypass the check.
    private func coordinateClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
