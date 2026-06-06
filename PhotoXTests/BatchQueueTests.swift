import XCTest
import IndexingCore
@testable import PhotoX

/// Pure coverage for the BatchQueue actor's ordering, prioritisation and
/// no-double-load invariants. Each indexing pipeline gets its own queue;
/// the contract here is what makes "navigate jumps + concurrent workers
/// + no duplicate exiftool spawns" all hold simultaneously.
///
/// XCTAssert* macros take autoclosures and don't support `await` inside,
/// so every awaited value is pulled into a local first.
final class BatchQueueTests: XCTestCase {

    func test_defaultOrder_isZeroThroughN() async {
        let q = BatchQueue(batchCount: 5)
        var seen: [Int] = []
        while let id = await q.popNext() { seen.append(id) }
        XCTAssertEqual(seen, [0, 1, 2, 3, 4])
    }

    func test_prioritize_pendingId_movesToHead() async {
        let q = BatchQueue(batchCount: 5)
        await q.prioritize(3)
        let first  = await q.popNext()
        let second = await q.popNext()
        let third  = await q.popNext()
        XCTAssertEqual(first,  3, "prioritized id should pop first")
        XCTAssertEqual(second, 0, "rest stay in original order")
        XCTAssertEqual(third,  1)
    }

    func test_prioritize_inProgressId_isNoop() async {
        let q = BatchQueue(batchCount: 3)
        _ = await q.popNext()              // 0 → .inProgress
        await q.prioritize(0)              // must be ignored — 0 is already running
        let next = await q.popNext()
        XCTAssertEqual(next, 1, "popNext must not re-hand out an in-progress id")
    }

    func test_prioritize_doneId_isNoop() async {
        let q = BatchQueue(batchCount: 3)
        let id = await q.popNext()!
        await q.markDone(id)
        await q.prioritize(id)
        // Pop should continue with the remaining pending ids; the done id
        // doesn't re-enter the queue.
        var rest: [Int] = []
        while let next = await q.popNext() { rest.append(next) }
        XCTAssertFalse(rest.contains(id),
                       "completed batch must not be re-handed out by popNext")
    }

    func test_popNext_returnsEachIdAtMostOnce_underConcurrency() async {
        // Spin up many concurrent claimers. The actor must serialise them
        // so every batch id appears in the union of returns exactly once.
        let q = BatchQueue(batchCount: 50)
        let claimed = await withTaskGroup(of: [Int].self,
                                          returning: [Int].self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    var local: [Int] = []
                    while let id = await q.popNext() { local.append(id) }
                    return local
                }
            }
            var all: [Int] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
        XCTAssertEqual(claimed.sorted(), Array(0 ..< 50),
                       "every id must be claimed exactly once across all workers")
    }

    func test_popNext_returnsNil_whenEmptyOrAllClaimed() async {
        let empty = BatchQueue(batchCount: 0)
        let emptyPop = await empty.popNext()
        XCTAssertNil(emptyPop)

        let q = BatchQueue(batchCount: 2)
        _ = await q.popNext()
        _ = await q.popNext()
        let drained = await q.popNext()
        XCTAssertNil(drained, "no claimable ids remain even if some are .inProgress")
    }

    func test_markDone_incrementsCount_idempotently() async {
        let q = BatchQueue(batchCount: 3)
        let a = await q.popNext()!
        let b = await q.popNext()!
        await q.markDone(a)
        let afterFirst = await q.snapshotDoneCount()
        XCTAssertEqual(afterFirst, 1)
        await q.markDone(a)
        let afterReMark = await q.snapshotDoneCount()
        XCTAssertEqual(afterReMark, 1, "re-marking a done id must not double-count")
        await q.markDone(b)
        let afterSecond = await q.snapshotDoneCount()
        XCTAssertEqual(afterSecond, 2)
    }

    func test_state_transitions_pendingInprogressDone() async {
        let q = BatchQueue(batchCount: 2)
        let s0 = await q.state(of: 0)
        XCTAssertEqual(s0, .pending)
        let id = await q.popNext()!
        let s1 = await q.state(of: id)
        XCTAssertEqual(s1, .inProgress)
        await q.markDone(id)
        let s2 = await q.state(of: id)
        XCTAssertEqual(s2, .done)
    }
}
