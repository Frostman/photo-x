import XCTest

/// Cache behavior: backward nav is instant on revisits, filmstrip
/// thumbs don't get evicted under normal use, and rapid HEIF↔RAW
/// toggling doesn't degrade nav latency.
///
/// These tests are sensitive to system load — keep them in a class
/// the user can run on its own (`just e2e PhotoXUITests/CachingTests`).
final class CachingTests: PhotoXSessionUITestCase {

    func test_filmstripThumbs_remainPresent() throws {
        waitForShootLoaded()

        // First few filmstrip thumbs should populate within ~5s of
        // launch. Index 0 is always visible (the leading edge of the
        // strip).
        let thumb0 = app.staticTexts["filmstrip.thumb.0"]
        XCTAssertTrue(thumb0.waitForExistence(timeout: 5),
                      "filmstrip thumb 0 should be present shortly after launch")

        // Jump to the end and back; thumb 0 must still be there
        // (i.e. the thumb cache didn't evict it during the round-trip).
        pressKey(.end)
        pressKey(.home)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(thumb0.exists,
                      "filmstrip thumb 0 should survive End→Home round-trip")
    }

    func test_repeatedToggle_doesNotDegradeNavLatency() throws {
        let total = waitForShootLoaded()
        XCTAssertGreaterThan(total, 5, "need at least 6 pairs")

        // Rapid Z toggles on the first pair — sniffs for texture-
        // pile-up / cache-leak that slows the next nav.
        for _ in 0 ..< 20 { pressKey("Z") }

        // After the toggle storm, → should still complete promptly.
        let start = Date()
        pressKey(.rightArrow)
        waitForPillIndex(2, total: total, timeout: 3)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0,
                          "→ after 20× Z took \(elapsed)s — cache leak suspected")
    }
}
