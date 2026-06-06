import XCTest
import IndexingCore
@testable import PhotoX

/// Pure-logic coverage for ViewerState's filter and navigation helpers.
/// Synthesises a Shoot from temp URLs and seeds entryXMPs directly so no
/// decoder, exiftool, or real file is exercised.
@MainActor
final class ViewerStateFilterTests: XCTestCase {

    // MARK: ratingCategory

    func test_ratingCategory_classifiesUnseenAsUnrated() {
        let state = ViewerState()
        XCTAssertEqual(state.ratingCategory(for: "missing"), .unrated)
    }

    func test_ratingCategory_classifiesByXMP() {
        let state = ViewerState()
        state.entryXMPs = [
            "A": XMPSidecar(rating: 5, label: nil),
            "B": XMPSidecar(rating: -1, label: nil),
            "C": XMPSidecar(rating: 0, label: nil),  // explicitly cleared = unrated
            "D": XMPSidecar(rating: nil, label: "Red"),
        ]
        XCTAssertEqual(state.ratingCategory(for: "A"), .rated(stars: 5))
        XCTAssertEqual(state.ratingCategory(for: "B"), .rejected)
        XCTAssertEqual(state.ratingCategory(for: "C"), .unrated)
        XCTAssertEqual(state.ratingCategory(for: "D"), .unrated,
                       "Label alone (no star rating) is not 'rated'")
    }

    // MARK: isVisible

    func test_isVisible_respectsAllShowToggles() {
        let state = makeState(stems: ["A", "B", "C"])
        state.entryXMPs = [
            "A": XMPSidecar(rating: 5),
            "B": XMPSidecar(rating: -1),
            "C": XMPSidecar(),
        ]
        let pairA = state.shoot!.entries[0]
        let pairB = state.shoot!.entries[1]
        let pairC = state.shoot!.entries[2]

        // All on → all visible
        XCTAssertTrue(state.isVisible(pairA))
        XCTAssertTrue(state.isVisible(pairB))
        XCTAssertTrue(state.isVisible(pairC))

        // Drop 5★ from showStars → A becomes hidden
        state.showStars.remove(5)
        XCTAssertFalse(state.isVisible(pairA))
        XCTAssertTrue(state.isVisible(pairB))
        XCTAssertTrue(state.isVisible(pairC))

        state.showStars.insert(5)
        state.showRejected = false
        XCTAssertFalse(state.isVisible(pairB))

        state.showRejected = true
        state.showUnrated = false
        XCTAssertFalse(state.isVisible(pairC))
    }

    func test_isVisible_perStarGranularity() {
        let state = makeState(stems: ["A", "B", "C", "D", "E"])
        state.entryXMPs = [
            "A": XMPSidecar(rating: 1),
            "B": XMPSidecar(rating: 2),
            "C": XMPSidecar(rating: 3),
            "D": XMPSidecar(rating: 4),
            "E": XMPSidecar(rating: 5),
        ]
        state.showStars = [3, 5]   // only show 3★ and 5★
        let pairs = state.shoot!.entries
        XCTAssertFalse(state.isVisible(pairs[0]))  // 1★
        XCTAssertFalse(state.isVisible(pairs[1]))  // 2★
        XCTAssertTrue (state.isVisible(pairs[2]))  // 3★
        XCTAssertFalse(state.isVisible(pairs[3]))  // 4★
        XCTAssertTrue (state.isVisible(pairs[4]))  // 5★
    }

    // MARK: shootStats + shownCount

    func test_shootStats_countsEachCategoryCorrectly() {
        let state = makeState(stems: ["A", "B", "C", "D", "E"])
        state.entryXMPs = [
            "A": XMPSidecar(rating: 5),
            "B": XMPSidecar(rating: 3),
            "C": XMPSidecar(rating: -1),
            // D, E unrated
        ]
        let s = state.shootStats
        XCTAssertEqual(s.rated,    2)
        XCTAssertEqual(s.rejected, 1)
        XCTAssertEqual(s.unrated,  2)
        XCTAssertEqual(s.total,    5)
        XCTAssertEqual(s.stars[5], 1)
        XCTAssertEqual(s.stars[3], 1)
        XCTAssertNil(s.stars[4])   // no 4-star pair
    }

    func test_shownCount_respectsPerStarToggles() {
        let state = makeState(stems: ["A", "B", "C", "D", "E"])
        state.entryXMPs = [
            "A": XMPSidecar(rating: 5),
            "B": XMPSidecar(rating: 3),
            "C": XMPSidecar(rating: -1),
        ]
        XCTAssertEqual(state.shownCount, 5)
        state.showRejected = false
        XCTAssertEqual(state.shownCount, 4)
        state.showStars.remove(5)
        XCTAssertEqual(state.shownCount, 3)
        state.showStars.remove(3)
        XCTAssertEqual(state.shownCount, 2)   // only unrated D, E
        state.showUnrated = false
        XCTAssertEqual(state.shownCount, 0)
    }

    func test_shootStats_zeroWhenNoShoot() {
        let state = ViewerState()
        XCTAssertEqual(state.shootStats.total, 0)
        XCTAssertEqual(state.shownCount, 0)
    }

    // MARK: navigation — indirectly exercises private nextVisibleIndex

    func test_navigate_to_clampsToValidRange() {
        let state = makeState(stems: ["A", "B", "C"])
        state.navigate(to: 99)
        XCTAssertEqual(state.currentIndex, 2)
        state.navigate(to: -5)
        XCTAssertEqual(state.currentIndex, 0)
    }

    func test_nextPair_skipsFilteredOutCategories() {
        let state = makeState(stems: ["A", "B", "C", "D"])
        state.entryXMPs = [
            "B": XMPSidecar(rating: -1),
            "C": XMPSidecar(rating: -1),
        ]
        state.showRejected = false   // hide B and C
        state.currentIndex = 0
        state.nextPair()
        XCTAssertEqual(state.currentIndex, 3,
                       "nextPair should skip B and C, landing on D")
    }

    func test_previousPair_skipsFilteredOutCategories() {
        let state = makeState(stems: ["A", "B", "C", "D"])
        state.entryXMPs = [
            "B": XMPSidecar(rating: -1),
            "C": XMPSidecar(rating: -1),
        ]
        state.showRejected = false
        state.currentIndex = 3
        state.previousPair()
        XCTAssertEqual(state.currentIndex, 0)
    }

    func test_nextPair_atEnd_isNoop() {
        let state = makeState(stems: ["A", "B"])
        state.currentIndex = 1
        state.nextPair()
        XCTAssertEqual(state.currentIndex, 1)
    }

    func test_firstAndLastPair_landOnVisibleEnds() {
        let state = makeState(stems: ["A", "B", "C", "D", "E"])
        state.entryXMPs = [
            "A": XMPSidecar(rating: -1),  // hidden
            "E": XMPSidecar(rating: -1),  // hidden
        ]
        state.showRejected = false
        state.currentIndex = 2
        state.firstPair()
        XCTAssertEqual(state.currentIndex, 1,
                       "firstPair skips hidden A → lands on B")
        state.lastPair()
        XCTAssertEqual(state.currentIndex, 3,
                       "lastPair skips hidden E → lands on D")
    }

    func test_navigate_by_walksAcrossVisiblePairsOnly() {
        let state = makeState(stems: ["A", "B", "C", "D", "E"])
        state.entryXMPs = ["C": XMPSidecar(rating: -1)]
        state.showRejected = false
        state.currentIndex = 0
        state.navigate(by: 2)
        XCTAssertEqual(state.currentIndex, 3,
                       "Skipping C, +2 steps from A lands on D")
        state.navigate(by: -1)
        XCTAssertEqual(state.currentIndex, 1)
    }

    // MARK: helpers

    private func makeState(stems: [String]) -> ViewerState {
        // Use file URLs that don't have to exist — the test only exercises the
        // filter/index logic, never the decoder pipeline. (loadShoot is bypassed.)
        let dir = URL(fileURLWithPath: "/tmp/photox-tests-fake")
        let pairs = stems.map { stem in
            PhotoEntry(
                rawURL: dir.appendingPathComponent("\(stem).ARW"),
                previewURL: dir.appendingPathComponent("\(stem).HIF"),
                stem: stem
            )
        }
        let state = ViewerState()
        state.shoot = Shoot(folderURL: dir, entries: pairs)
        return state
    }
}
