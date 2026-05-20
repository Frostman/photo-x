import XCTest

/// Smoke: app launches, loads the fixture, shows the first pair.
/// If this fails, every other test in the bundle is also suspect —
/// the base class's launch path isn't doing what we think.
final class SmokeTests: PhotoXUITestCase {

    func test_launch_loadsFixture_andShowsFirstPair() throws {
        let total = waitForShootLoaded()
        let expected = try sortedPairStems().count
        XCTAssertEqual(total, expected,
                       "stem-pill total should match number of paired ARW+HIF stems")
        waitForPillIndex(1, total: total)
        XCTAssertEqual(currentStem(), try sortedPairStems().first,
                       "fresh shoot focuses the first pair (sorted by name)")
    }
}
