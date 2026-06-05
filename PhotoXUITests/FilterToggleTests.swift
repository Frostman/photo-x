import XCTest

/// XCUITest coverage for the status-bar filter toggles. Five
/// per-star toggles (`statusbar.filter.star.1` … `.star.5`) plus
/// rejected (`statusbar.filter.showRejected`) and unrated
/// (`statusbar.filter.showUnrated`) — together they control which
/// frames are visible in the filmstrip. The "X shown" status-bar
/// text (`statusbar.shownCount`) is the deterministic assertion
/// target: it recomputes synchronously on every toggle flip.
///
/// Sample fixture has 61 entries split rated=18 / rejected=8 /
/// unrated=35 (see `StatusBarView.stats` log at session start).
/// All toggles default to ON so `shown == 61` at launch.
final class FilterToggleTests: PhotoXSessionUITestCase {

    private var shownCount: Int {
        let raw = (app.staticTexts["statusbar.shownCount"].value as? String) ?? ""
        return Int(raw.split(separator: " ").first.map(String.init) ?? "") ?? -1
    }

    private func toggleVisible() {
        // Ensure the filmstrip is visible — without it, the shown-
        // count text is hidden and the assertion below would read
        // -1. The status-bar toggle is `filmstrip.visible`-driven
        // (StatusBarView line ~195) and starts on; this is belt-
        // and-suspenders for `resetForUITest()`-set defaults.
        if !app.staticTexts["statusbar.shownCount"].exists {
            // Filmstrip visibility toggle is on `T` — see ContentView.handleKeyDown.
            pressKey("T")
        }
    }

    func test_uncheckRejected_dropsRejectedFromShown() throws {
        _ = waitForShootLoaded()
        waitForIndexingDone()
        toggleVisible()

        let initial = shownCount
        XCTAssertEqual(initial, 61, "fixture should start with all 61 entries shown")

        app.checkBoxes["statusbar.filter.showRejected"].click()
        // SwiftUI updates the count synchronously; one settle tick.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(shownCount, 53, "61 − 8 rejected = 53 shown")

        // Re-enable and assert symmetry.
        app.checkBoxes["statusbar.filter.showRejected"].click()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(shownCount, 61, "all entries shown after re-enabling rejected filter")
    }

    func test_uncheckUnrated_dropsUnratedFromShown() throws {
        _ = waitForShootLoaded()
        waitForIndexingDone()
        toggleVisible()

        app.checkBoxes["statusbar.filter.showUnrated"].click()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(shownCount, 26, "61 − 35 unrated = 26 shown")
    }

    func test_uncheckAllStars_dropsAllRated() throws {
        _ = waitForShootLoaded()
        waitForIndexingDone()
        toggleVisible()

        // Click every per-star toggle off. They start on.
        for stars in 1 ... 5 {
            app.checkBoxes["statusbar.filter.star.\(stars)"].click()
        }
        Thread.sleep(forTimeInterval: 0.15)
        // 18 rated entries removed; 35 unrated + 8 rejected remain.
        XCTAssertEqual(shownCount, 43,
                       "all five star toggles off should leave 35 unrated + 8 rejected = 43")
    }
}
