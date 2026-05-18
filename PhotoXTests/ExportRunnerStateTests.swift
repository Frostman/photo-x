import XCTest
@testable import PhotoX

/// Coverage for the runner's state-machine surface — start/cancel,
/// queued → running → done transitions, isRunning, overallProgress.
@MainActor
final class ExportRunnerStateTests: XCTestCase {

    private var tmpRoot: URL!
    private var sourceDir: URL!
    private var destDirA: URL!
    private var destDirB: URL!
    private var runner: ExportRunner!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("photox-runner-tests-\(UUID().uuidString)")
        sourceDir = tmpRoot.appendingPathComponent("src")
        destDirA = tmpRoot.appendingPathComponent("dstA")
        destDirB = tmpRoot.appendingPathComponent("dstB")
        for dir in [sourceDir, destDirA, destDirB] {
            try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        }
        runner = ExportRunner()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func makePair(_ stem: String, bytes: Int = 1024) throws -> PhotoPair {
        let arw = sourceDir.appendingPathComponent("\(stem).ARW")
        let hif = sourceDir.appendingPathComponent("\(stem).HIF")
        try Data(repeating: 1, count: bytes).write(to: arw)
        try Data(repeating: 2, count: bytes).write(to: hif)
        return PhotoPair(rawURL: arw, heifURL: hif, stem: stem)
    }

    private func dest(at url: URL,
                      overwrite: ExportSettings.OverwritePolicy = .skipUnchangedElseOverwrite
    ) -> ExportSettings.Destination {
        ExportSettings.Destination(path: url.path, overwrite: overwrite, removeOrphans: false)
    }

    // MARK: tests

    func test_startAll_emptyDestinations_isNoOp() async {
        runner.startAll(pairs: [], pairXMPs: [:],
                        projectName: "P", destinations: [],
                        notifications: .silent)
        await runner.waitForCompletion()
        XCTAssertTrue(runner.perDestination.isEmpty)
        XCTAssertFalse(runner.isRunning)
    }

    func test_startOne_doesNotTouchOtherDestinations() async throws {
        let p = try makePair("X")
        let d1 = dest(at: destDirA)
        let d2 = dest(at: destDirB)
        runner.startOne(d1.id, pairs: [p], pairXMPs: [:],
                        projectName: "P", destination: d1, notifications: .silent)
        await runner.waitForCompletion()
        XCTAssertNotNil(runner.perDestination[d1.id])
        XCTAssertNil(runner.perDestination[d2.id])
    }

    func test_terminalStates_areCapturedAfterRun() async throws {
        let p = try makePair("X")
        let d = dest(at: destDirA)
        runner.startOne(d.id, pairs: [p], pairXMPs: [:],
                        projectName: "P", destination: d, notifications: .silent)
        await runner.waitForCompletion()
        switch runner.perDestination[d.id] {
        case .done(let s):
            XCTAssertEqual(s.copied, 2)        // ARW + HIF (no XMP file in this pair)
            XCTAssertEqual(s.errors.count, 0)
        default:
            XCTFail("expected .done, got \(String(describing: runner.perDestination[d.id]))")
        }
        XCTAssertFalse(runner.isRunning)
    }

    func test_isRunning_isTrueWhileQueued() async throws {
        // Queue but don't await — at the instant after startAll returns,
        // at least one destination should be queued or running.
        let p = try makePair("X")
        let d = dest(at: destDirA)
        runner.startAll(pairs: [p], pairXMPs: [:],
                        projectName: "P", destinations: [d],
                        notifications: .silent)
        // queued counts as "in flight" for the purposes of letting the
        // toolbar pill stay visible — verify via hasQueued.
        XCTAssertTrue(runner.hasQueued || runner.isRunning)
        await runner.waitForCompletion()
        XCTAssertFalse(runner.isRunning)
        XCTAssertFalse(runner.hasQueued)
    }

    func test_startAll_sequenceProducesDoneStatesPerDestination() async throws {
        let p = try makePair("X")
        let d1 = dest(at: destDirA)
        let d2 = dest(at: destDirB)
        runner.startAll(pairs: [p], pairXMPs: [:],
                        projectName: "P", destinations: [d1, d2],
                        notifications: .silent)
        await runner.waitForCompletion()
        for id in [d1.id, d2.id] {
            if case .done = runner.perDestination[id] { /* ok */ }
            else { XCTFail("destination \(id) didn't reach .done") }
        }
    }

    func test_cancelAll_beforeAnyWork_yieldsCancelledStates() async throws {
        let p = try makePair("X")
        let d1 = dest(at: destDirA)
        let d2 = dest(at: destDirB)
        runner.startAll(pairs: [p], pairXMPs: [:],
                        projectName: "P", destinations: [d1, d2],
                        notifications: .silent)
        runner.cancelAll()
        await runner.waitForCompletion()
        // At least one destination should be cancelled (depending on timing,
        // the first one might be partially complete or fully done).
        let cancelled = runner.perDestination.values.contains {
            if case .cancelled = $0 { return true } else { return false }
        }
        let runAtAll = runner.perDestination.values.contains {
            if case .done = $0 { return true } else { return false }
        }
        XCTAssertTrue(cancelled || !runAtAll,
                      "expected at least one cancelled, or nothing ran at all")
    }

    func test_overallProgress_isNil_whenNothingRunning() async {
        XCTAssertNil(runner.overallProgress)
    }

    func test_summary_recordsCopiedAndSkippedOnRerun() async throws {
        let p = try makePair("X")
        let d = dest(at: destDirA)
        runner.startOne(d.id, pairs: [p], pairXMPs: [:],
                        projectName: "P", destination: d, notifications: .silent)
        await runner.waitForCompletion()

        // Second run — files should now be skipped.
        runner.startOne(d.id, pairs: [p], pairXMPs: [:],
                        projectName: "P", destination: d, notifications: .silent)
        await runner.waitForCompletion()
        guard case .done(let s) = runner.perDestination[d.id] else {
            return XCTFail("expected .done after re-run")
        }
        XCTAssertEqual(s.copied, 0)
        XCTAssertEqual(s.skipped, 2)
    }
}
