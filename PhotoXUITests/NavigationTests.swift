import XCTest

/// Arrow-key navigation: forward / back, ⌥ jumps ±10, Home/End,
/// burst-press (50 ←/→ in a row) doesn't corrupt the index.
///
/// Every key-press is followed by `waitForPillIndex(...)` (predicate
/// expectation) — XCUITest's a11y snapshot cache doesn't refresh on
/// SwiftUI value-only updates, so a direct read after `pressKey`
/// returns the stale prior value.
final class NavigationTests: PhotoXUITestCase {

    func test_rightArrow_advancesByOne() throws {
        let total = waitForShootLoaded()
        XCTAssertGreaterThan(total, 1)

        pressKey(.rightArrow)
        waitForPillIndex(2, total: total)
    }

    func test_leftArrow_goesBack() throws {
        let total = waitForShootLoaded()
        pressKey(.rightArrow)
        waitForPillIndex(2, total: total)
        pressKey(.rightArrow)
        waitForPillIndex(3, total: total)
        pressKey(.leftArrow)
        waitForPillIndex(2, total: total)
    }

    func test_rightArrow_atEnd_clamps() throws {
        let total = waitForShootLoaded()
        pressKey(.end)
        waitForPillIndex(total, total: total)
        pressKey(.rightArrow)
        // Pin observed behavior: clamps at last index, doesn't wrap.
        // No state change → predicate-wait would time out; verify
        // directly via a fresh read after a settle.
        Thread.sleep(forTimeInterval: 1.0)
        let pill = app.staticTexts["canvas.stemPill.indexLabel"]
        XCTAssertEqual(pill.value as? String, "\(total)/\(total)",
                       "navigating past the last pair should clamp, not wrap")
    }

    func test_optionArrow_stepsByTen() throws {
        let total = waitForShootLoaded()
        XCTAssertGreaterThanOrEqual(total, 11,
                                     "need at least 11 pairs to test ±10")
        pressKey(.rightArrow, modifiers: .option)
        waitForPillIndex(11, total: total)
        pressKey(.leftArrow, modifiers: .option)
        waitForPillIndex(1, total: total)
    }

    func test_homeEnd_jumpToBoundaries() throws {
        let total = waitForShootLoaded()
        pressKey(.end)
        waitForPillIndex(total, total: total)
        pressKey(.home)
        waitForPillIndex(1, total: total)
    }

    func test_arrowSpam_doesNotCorruptIndex() throws {
        let total = waitForShootLoaded()
        let target = min(51, total)   // 50 presses from 1 → 51, clamped to total
        for _ in 0 ..< 50 {
            pressKey(.rightArrow)
        }
        // SwiftUI coalesces the redraws; a longer wait covers the
        // worst-case where the canvas is still decoding mid-burst.
        waitForPillIndex(target, total: total, timeout: 10)
    }
}
