import XCTest

/// Indexer integration: every pair found.
///
/// Two follow-up tests from the plan are intentionally deferred:
///
/// 1. `test_indexer_populatesEXIFForEveryPair` — walks all pairs
///    asserting EXIF panel populates per-pair. Currently flaky on
///    rapid nav because the snapshot query for the next pair's row
///    sometimes runs before the SwiftUI tree restructures. Needs a
///    settle-step that doesn't double the test runtime.
///
/// 2. `test_indexer_readsPreExistingXMP` — seeds a known XMP before
///    launch and verifies the app reads it. Currently can't be
///    asserted via XCUITest because SwiftUI Buttons don't expose
///    selected-state in the accessibility tree by default. Needs
///    `.accessibilityValue("1"/"0")` on the star buttons (small
///    code change) — added together with the next round of
///    indexer tests.
final class IndexingTests: PhotoXSessionUITestCase {

    func test_indexer_findsEveryPair() throws {
        let total = waitForShootLoaded()
        let expected = try sortedPairStems().count
        XCTAssertEqual(total, expected,
                       "indexer should report exactly \(expected) ARW+HIF pairs")
    }
}
