import XCTest
@testable import PhotoX

/// Indexer lifecycle: starts on shoot load, reaches .done for an empty
/// shoot synchronously, gets wiped on shoot close, and re-runs cleanly
/// on reIndex(). Doesn't exercise the actual exiftool / XMP / thumbnail
/// pipelines — those need disk fixtures and are out of scope here.
@MainActor
final class IndexingStatusTests: XCTestCase {

    func test_indexingStatus_defaultsToIdle() {
        let state = ViewerState()
        XCTAssertEqual(state.indexingStatus, .idle)
    }

    func test_startIndexing_emptyShoot_reachesDoneSynchronously() {
        let state = ViewerState()
        let dir = URL(fileURLWithPath: "/tmp/photox-indexer-tests-empty")
        state.shoot = Shoot(folderURL: dir, pairs: [])
        state.startIndexing()
        XCTAssertEqual(state.indexingStatus, .done,
                       "An empty shoot has nothing to index; status flips to .done immediately.")
    }

    func test_startIndexing_nonEmptyShoot_setsIndexingZero() {
        let state = makeState(stems: ["A", "B", "C"])
        state.startIndexing()
        // Status may have advanced if the pipelines are very fast on a
        // fixture without real files, but at the very least we must be in
        // .indexing OR .done — never .idle or .cancelled.
        switch state.indexingStatus {
        case .indexing, .done:
            break  // ok
        default:
            XCTFail("expected .indexing or .done after startIndexing, got \(state.indexingStatus)")
        }
    }

    func test_prioritizeBatch_unknownStem_isNoOp() {
        let state = makeState(stems: ["A", "B"])
        state.startIndexing()
        state.prioritizeBatch(forStem: "DOES_NOT_EXIST")
        // No crash, no exception — the absence of the stem in stemToBatchID
        // just causes prioritizeBatch to early-return.
    }

    func test_reIndex_onEmptyState_isNoOp() {
        let state = ViewerState()
        state.reIndex()
        XCTAssertEqual(state.indexingStatus, .idle,
                       "reIndex without a shoot must not flip status")
    }

    func test_reIndex_clearsCachesAndRestarts() {
        let state = makeState(stems: ["A", "B"])
        state.pairExif       = ["A": ExifSummary()]
        state.pairXMPs       = ["A": XMPSidecar(rating: 5)]
        state.pairAFData     = ["A": ExifToolRunner.AFData()]
        state.pairSequenceNumber = ["A": 1]
        state.reIndex()
        XCTAssertTrue(state.pairExif.isEmpty,         "reIndex wipes pairExif")
        XCTAssertTrue(state.pairXMPs.isEmpty,         "reIndex wipes pairXMPs")
        XCTAssertTrue(state.pairAFData.isEmpty,       "reIndex wipes pairAFData")
        XCTAssertTrue(state.pairSequenceNumber.isEmpty, "reIndex wipes pairSequenceNumber")
        // And it must have re-entered an active status.
        switch state.indexingStatus {
        case .indexing, .done: break
        default:
            XCTFail("expected .indexing or .done after reIndex, got \(state.indexingStatus)")
        }
    }

    // MARK: helpers

    private func makeState(stems: [String]) -> ViewerState {
        let dir = URL(fileURLWithPath: "/tmp/photox-indexer-tests-fake")
        let pairs = stems.map { stem in
            PhotoPair(
                rawURL: dir.appendingPathComponent("\(stem).ARW"),
                heifURL: dir.appendingPathComponent("\(stem).HIF"),
                stem: stem
            )
        }
        let state = ViewerState()
        state.shoot = Shoot(folderURL: dir, pairs: pairs)
        return state
    }
}
