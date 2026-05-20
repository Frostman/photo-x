import XCTest

/// View toggles: HEIF↔RAW (Z), sidebar (B), filmstrip (T). These are
/// pure-UI assertions — no fixture mutation involved.
final class ViewToggleTests: PhotoXUITestCase {

    func test_previewRawToggle_updatesStatusText() throws {
        waitForShootLoaded()
        let status = app.staticTexts["canvas.statusText"]
        XCTAssertTrue(status.waitForExistence(timeout: 3),
                      "canvas.statusText should exist once an entry is shown")
        let before = (status.value as? String) ?? ""
        // First entry might be either preview format depending on
        // what sorts first alphabetically in the fixture; either is
        // a valid starting point. We just care that it's NOT RAW.
        XCTAssertTrue(before.contains("HEIF") || before.contains("JPEG"),
                      "fresh load starts on a preview format; got '\(before)'")

        pressKey("Z")
        // Status text changes its label string → predicate-wait until
        // it begins with "RAW".
        let pred = NSPredicate(format: "value BEGINSWITH %@", "RAW")
        let exp = XCTNSPredicateExpectation(predicate: pred, object: status)
        let res = XCTWaiter.wait(for: [exp], timeout: 5)
        XCTAssertEqual(res, .completed,
                       "Z should switch status to RAW within 5s; current='\(status.value ?? "")'")
    }

    func test_sidebarToggle_hidesAndRestores() throws {
        waitForShootLoaded()
        let sidebar = app.scrollViews["sidebar.container"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3))

        pressKey("B")
        // Visibility transitions are SwiftUI-animated; need a wait.
        let hidden = NSPredicate(format: "exists == false")
        let exp1 = XCTNSPredicateExpectation(predicate: hidden, object: sidebar)
        XCTAssertEqual(XCTWaiter.wait(for: [exp1], timeout: 3), .completed,
                       "B should hide the sidebar")

        pressKey("B")
        let shown = NSPredicate(format: "exists == true")
        let exp2 = XCTNSPredicateExpectation(predicate: shown, object: sidebar)
        XCTAssertEqual(XCTWaiter.wait(for: [exp2], timeout: 3), .completed,
                       "B again should restore the sidebar")
    }

    func test_filmstripToggle_hidesAndRestores() throws {
        waitForShootLoaded()
        let strip = app.scrollViews["filmstrip.container"]
        XCTAssertTrue(strip.waitForExistence(timeout: 3))

        pressKey("T")
        let hidden = NSPredicate(format: "exists == false")
        let exp1 = XCTNSPredicateExpectation(predicate: hidden, object: strip)
        XCTAssertEqual(XCTWaiter.wait(for: [exp1], timeout: 3), .completed,
                       "T should hide the filmstrip")

        pressKey("T")
        let shown = NSPredicate(format: "exists == true")
        let exp2 = XCTNSPredicateExpectation(predicate: shown, object: strip)
        XCTAssertEqual(XCTWaiter.wait(for: [exp2], timeout: 3), .completed,
                       "T again should restore the filmstrip")
    }
}
