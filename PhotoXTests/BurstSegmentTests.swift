import XCTest
@testable import PhotoX

/// Pure-logic coverage for ViewerState's burst-grouping helpers — the
/// `burstIDByStem` cache and the per-thumbnail `burstSegment(at:visible:)`
/// decider that drives the filmstrip's top-edge bracket overlay.
///
/// Burst ids are computed against the FULL shoot's name-sorted pair list,
/// so a filter that hides middle frames must NOT split a burst into
/// separate brackets — that's the behaviour these tests pin down.
@MainActor
final class BurstSegmentTests: XCTestCase {

    // MARK: burstIDByStem

    func test_burstIDByStem_groupsConsecutiveSequenceNumbers() {
        let state = makeState(stems: ["A", "B", "C"], seq: ["A": 1, "B": 2, "C": 3])
        let ids = state.burstIDByStem
        XCTAssertEqual(ids["A"], ids["B"])
        XCTAssertEqual(ids["B"], ids["C"])
    }

    func test_burstIDByStem_breaksOnGap() {
        // A(1) B(2) C(4) — C is not 2+1, so it starts a new burst.
        let state = makeState(stems: ["A", "B", "C"], seq: ["A": 1, "B": 2, "C": 4])
        let ids = state.burstIDByStem
        XCTAssertEqual(ids["A"], ids["B"])
        XCTAssertNotEqual(ids["B"], ids["C"])
    }

    func test_burstIDByStem_breaksOnMissingFrame() {
        // A(1) B(nil) C(2) — the gap pair has no number, so C starts fresh.
        let state = makeState(stems: ["A", "B", "C"], seq: ["A": 1, "C": 2])
        let ids = state.burstIDByStem
        XCTAssertNotNil(ids["A"])
        XCTAssertNil(ids["B"])
        XCTAssertNotNil(ids["C"])
        XCTAssertNotEqual(ids["A"], ids["C"])
    }

    func test_burstIDByStem_independentOfFilter() {
        // Even with all rejected (everything filtered out), burst ids are
        // still computed off the full shoot.
        let state = makeState(stems: ["A", "B", "C"], seq: ["A": 1, "B": 2, "C": 3])
        state.pairXMPs = [
            "A": XMPSidecar(rating: -1),
            "B": XMPSidecar(rating: -1),
            "C": XMPSidecar(rating: -1),
        ]
        state.showRejected = false
        let ids = state.burstIDByStem
        XCTAssertEqual(ids["A"], ids["B"])
        XCTAssertEqual(ids["B"], ids["C"])
    }

    // MARK: burstSegment — happy path

    func test_burstSegment_threeFrameBurst_allVisible() {
        let state = makeState(stems: ["A", "B", "C"], seq: ["A": 1, "B": 2, "C": 3])
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        XCTAssertEqual(state.burstSegment(at: 0, visible: visible), .start)
        XCTAssertEqual(state.burstSegment(at: 1, visible: visible), .middle)
        XCTAssertEqual(state.burstSegment(at: 2, visible: visible), .end)
    }

    func test_burstSegment_singletonsInterleavedWithBurst() {
        // A(nil), B(1), C(2), D(nil) → only B/C form a burst.
        let state = makeState(
            stems: ["A", "B", "C", "D"],
            seq: ["B": 1, "C": 2]
        )
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        XCTAssertEqual(state.burstSegment(at: 0, visible: visible), .none)
        XCTAssertEqual(state.burstSegment(at: 1, visible: visible), .start)
        XCTAssertEqual(state.burstSegment(at: 2, visible: visible), .end)
        XCTAssertEqual(state.burstSegment(at: 3, visible: visible), .none)
    }

    func test_burstSegment_burstOfTwo() {
        let state = makeState(stems: ["A", "B"], seq: ["A": 1, "B": 2])
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        XCTAssertEqual(state.burstSegment(at: 0, visible: visible), .start)
        XCTAssertEqual(state.burstSegment(at: 1, visible: visible), .end)
    }

    func test_burstSegment_loneBurstMember() {
        // A pair tagged with a sequence number all by itself isn't a burst —
        // the bracket would have nothing to span.
        let state = makeState(stems: ["A"], seq: ["A": 1])
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        XCTAssertEqual(state.burstSegment(at: 0, visible: visible), .none)
    }

    func test_burstSegment_twoConsecutiveBurstsWithReset() {
        // A(3) B(4) | C(1) D(2) — sequence resets between bursts.
        let state = makeState(
            stems: ["A", "B", "C", "D"],
            seq: ["A": 3, "B": 4, "C": 1, "D": 2]
        )
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        XCTAssertEqual(state.burstSegment(at: 0, visible: visible), .start)
        XCTAssertEqual(state.burstSegment(at: 1, visible: visible), .end)
        XCTAssertEqual(state.burstSegment(at: 2, visible: visible), .start)
        XCTAssertEqual(state.burstSegment(at: 3, visible: visible), .end)
    }

    // MARK: burstSegment — sort gating

    func test_burstSegment_hiddenInScoreSort() {
        let state = makeState(stems: ["A", "B", "C"], seq: ["A": 1, "B": 2, "C": 3])
        state.pairXMPs = [
            "A": XMPSidecar(rating: 3),
            "B": XMPSidecar(rating: 5),
            "C": XMPSidecar(rating: 1),
        ]
        state.setSortMode(.scoreAscending)
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        for i in visible.indices {
            XCTAssertEqual(state.burstSegment(at: i, visible: visible), .none,
                           "brackets must be hidden in score mode")
        }
        state.setSortMode(.scoreDescending)
        let visibleDesc = state.sortedPairs.filter { state.isVisible($0) }
        for i in visibleDesc.indices {
            XCTAssertEqual(state.burstSegment(at: i, visible: visibleDesc), .none)
        }
    }

    // MARK: burstSegment — filter resilience (the main reason for the cache)

    func test_burstSegment_filterHidesMiddleFrames_keepsSingleBracket() {
        // Full burst: A(1) B(2) C(3) D(4) E(5). Hide B and D (e.g. rejected).
        // Remaining visible A, C, E still share one burst id, so they read
        // as one bracket: start / middle / end across A → C → E.
        let state = makeState(
            stems: ["A", "B", "C", "D", "E"],
            seq: ["A": 1, "B": 2, "C": 3, "D": 4, "E": 5]
        )
        state.pairXMPs = [
            "B": XMPSidecar(rating: -1),
            "D": XMPSidecar(rating: -1),
        ]
        state.showRejected = false
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        XCTAssertEqual(visible.map(\.stem), ["A", "C", "E"])
        XCTAssertEqual(state.burstSegment(at: 0, visible: visible), .start)
        XCTAssertEqual(state.burstSegment(at: 1, visible: visible), .middle)
        XCTAssertEqual(state.burstSegment(at: 2, visible: visible), .end)
    }

    func test_burstSegment_filterLeavesAdjacentSubclusterFromTwoBursts() {
        // Bursts: A(1) B(2) | D(4) is a singleton run start. Visible A, B, D
        // — A,B share an id; D is a different burst (and a singleton run by
        // itself once filtered → .none).
        let state = makeState(
            stems: ["A", "B", "C", "D"],
            seq: ["A": 1, "B": 2, "D": 4]
        )
        state.pairXMPs = ["C": XMPSidecar(rating: -1)]
        state.showRejected = false
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        XCTAssertEqual(visible.map(\.stem), ["A", "B", "D"])
        XCTAssertEqual(state.burstSegment(at: 0, visible: visible), .start)
        XCTAssertEqual(state.burstSegment(at: 1, visible: visible), .end)
        XCTAssertEqual(state.burstSegment(at: 2, visible: visible), .none)
    }

    func test_burstSegment_onlyOneBurstMemberVisible() {
        // Hide B, D — but also hide A, E (leave just C visible). C has no
        // visible burst neighbour, so no bracket to draw.
        let state = makeState(
            stems: ["A", "B", "C", "D", "E"],
            seq: ["A": 1, "B": 2, "C": 3, "D": 4, "E": 5]
        )
        state.pairXMPs = [
            "A": XMPSidecar(rating: -1),
            "B": XMPSidecar(rating: -1),
            "D": XMPSidecar(rating: -1),
            "E": XMPSidecar(rating: -1),
        ]
        state.showRejected = false
        let visible = state.sortedPairs.filter { state.isVisible($0) }
        XCTAssertEqual(visible.map(\.stem), ["C"])
        XCTAssertEqual(state.burstSegment(at: 0, visible: visible), .none)
    }

    // MARK: helpers

    private func makeState(stems: [String], seq: [String: Int]) -> ViewerState {
        let dir = URL(fileURLWithPath: "/tmp/photox-burst-tests-fake")
        let pairs = stems.map { stem in
            PhotoPair(
                rawURL: dir.appendingPathComponent("\(stem).ARW"),
                heifURL: dir.appendingPathComponent("\(stem).HIF"),
                stem: stem
            )
        }
        let state = ViewerState()
        state.shoot = Shoot(folderURL: dir, pairs: pairs)
        state.pairSequenceNumber = seq
        return state
    }
}
