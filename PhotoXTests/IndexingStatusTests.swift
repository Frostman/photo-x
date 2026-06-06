import XCTest
import IndexingCore
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
        state.shoot = Shoot(folderURL: dir, entries: [])
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

    // MARK: PipelineTiming

    func test_pipelineTiming_eta_isNil_beforeAnyProgress() {
        let t = ViewerState.PipelineTiming(startedAt: 1000.0)
        XCTAssertNil(t.eta(progress: 0,    now: 1001.0))
        XCTAssertNil(t.eta(progress: 0.005, now: 1001.0))
        XCTAssertNil(t.eta(progress: 1.0,  now: 1001.0),
                     "at 100% there's nothing left to estimate")
    }

    func test_pipelineTiming_eta_isNil_inFirstHalfSecond() {
        // Too noisy to estimate from <500 ms of signal.
        let t = ViewerState.PipelineTiming(startedAt: 1000.0)
        XCTAssertNil(t.eta(progress: 0.10, now: 1000.3))
    }

    func test_pipelineTiming_eta_isElapsedTimesRemainingOverProgress() {
        // After 10 s at 25% progress, ETA = 10 × (0.75 / 0.25) = 30 s.
        let t = ViewerState.PipelineTiming(startedAt: 1000.0)
        let eta = t.eta(progress: 0.25, now: 1010.0)
        XCTAssertEqual(eta ?? 0, 30.0, accuracy: 0.001)
    }

    func test_pipelineTiming_eta_returnsNil_oncefinishedAtSet() {
        var t = ViewerState.PipelineTiming(startedAt: 1000.0)
        t.finishedAt = 1018.0
        XCTAssertNil(t.eta(progress: 0.5, now: 1010.0),
                     "no ETA once the pipeline has finished")
    }

    func test_pipelineTiming_duration_isFinishedMinusStarted() {
        var t = ViewerState.PipelineTiming(startedAt: 1000.0)
        XCTAssertNil(t.duration, "no duration until finishedAt is set")
        t.finishedAt = 1018.5
        XCTAssertEqual(t.duration ?? 0, 18.5, accuracy: 0.001)
    }

    // MARK: reIndex

    func test_reIndex_clearsCachesAndRestarts() {
        let state = makeState(stems: ["A", "B"])
        state.entryExif       = ["A": ExifSummary()]
        state.entryXMPs       = ["A": XMPSidecar(rating: 5)]
        state.entryAFData     = ["A": ExifToolRunner.AFData()]
        state.entrySequenceNumber = ["A": 1]
        state.reIndex()
        XCTAssertTrue(state.entryExif.isEmpty,         "reIndex wipes entryExif")
        XCTAssertTrue(state.entryXMPs.isEmpty,         "reIndex wipes entryXMPs")
        XCTAssertTrue(state.entryAFData.isEmpty,       "reIndex wipes entryAFData")
        XCTAssertTrue(state.entrySequenceNumber.isEmpty, "reIndex wipes entrySequenceNumber")
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
