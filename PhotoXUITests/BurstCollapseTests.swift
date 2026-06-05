import XCTest

/// XCUITest coverage for the status-bar burst-collapse toggle
/// (`statusbar.collapseBursts`, StatusBarView.swift `collapseBurstsButton`).
///
/// The button uses `rectangle.stack` (off) / `rectangle.stack.fill`
/// (on) SF Symbols, but macOS exposes the human-readable AX label
/// "Album" for both — it doesn't change with the icon swap. To make
/// the toggle observable, `StatusBarView.collapseBurstsButton` sets
/// `.accessibilityValue("0" | "1")` from the same `effective`
/// computation that drives the icon variant. Tests assert on `value`.
final class BurstCollapseTests: PhotoXSessionUITestCase {

    func test_collapseButton_togglesValue() throws {
        _ = waitForShootLoaded()
        // The button is `.disabled` while `state.isIndexingActive`,
        // so wait for the indexer chip to flip to `.done`.
        waitForIndexingDone()

        let button = app.buttons["statusbar.collapseBursts"]
        XCTAssertTrue(button.waitForExistence(timeout: 3),
                      "collapse-bursts button missing")
        XCTAssertEqual(button.value as? String, "0",
                       "default state should be collapse-off")

        button.click()
        let onPred = NSPredicate(format: "value == '1'")
        let onExp = XCTNSPredicateExpectation(predicate: onPred, object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [onExp], timeout: 2), .completed,
                       "button value should flip to '1' after first click")

        button.click()
        let offPred = NSPredicate(format: "value == '0'")
        let offExp = XCTNSPredicateExpectation(predicate: offPred, object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [offExp], timeout: 2), .completed,
                       "button value should flip back to '0' after second click")
    }
}
