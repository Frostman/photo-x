import XCTest
import IndexingCore
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

    private func makePair(_ stem: String, bytes: Int = 1024) throws -> PhotoEntry {
        let arw = sourceDir.appendingPathComponent("\(stem).ARW")
        let hif = sourceDir.appendingPathComponent("\(stem).HIF")
        try Data(repeating: 1, count: bytes).write(to: arw)
        try Data(repeating: 2, count: bytes).write(to: hif)
        return PhotoEntry(rawURL: arw, previewURL: hif, stem: stem)
    }

    private func dest(at url: URL,
                      overwrite: ExportPreset.OverwritePolicy = .skipUnchangedElseOverwrite
    ) -> ExportPreset.Destination {
        // `allowNonEmpty: true` so this suite's re-run tests
        // (test_summary_recordsCopiedAndSkippedOnRerun, …)
        // aren't blocked by the new "Destination not empty"
        // gate.
        ExportPreset.Destination(path: url.path,
                                   overwrite: overwrite,
                                   allowNonEmpty: true,
                                   removeOrphans: false)
    }

    // MARK: tests

    func test_startAll_emptyDestinations_isNoOp() async {
        runner.startAll(entries: [], entryXMPs: [:],
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
        runner.startOne(d1.id, entries: [p], entryXMPs: [:],
                        projectName: "P", destination: d1, notifications: .silent)
        await runner.waitForCompletion()
        XCTAssertNotNil(runner.perDestination[d1.id])
        XCTAssertNil(runner.perDestination[d2.id])
    }

    func test_terminalStates_areCapturedAfterRun() async throws {
        let p = try makePair("X")
        let d = dest(at: destDirA)
        runner.startOne(d.id, entries: [p], entryXMPs: [:],
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
        runner.startAll(entries: [p], entryXMPs: [:],
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
        runner.startAll(entries: [p], entryXMPs: [:],
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
        runner.startAll(entries: [p], entryXMPs: [:],
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

    func test_sleepAssertion_isHeldDuringRun_andReleasedAfter() async throws {
        let p = try makePair("X")
        let d = dest(at: destDirA)

        XCTAssertFalse(runner.isPreventingSleep, "no assertion before start")

        // The runner acquires the assertion synchronously in startOne so
        // the moment this returns, isPreventingSleep must be true — no
        // polling, no race.
        runner.startOne(d.id, entries: [p], entryXMPs: [:],
                        projectName: "P", destination: d, notifications: .silent)
        XCTAssertTrue(runner.isPreventingSleep,
                      "assertion must be held the moment startOne returns")

        await runner.waitForCompletion()
        XCTAssertFalse(runner.isPreventingSleep,
                       "assertion must be released after the batch finishes")
    }

    func test_sleepAssertion_isHeldAcrossMultipleDestinations() async throws {
        let p = try makePair("X")
        let d1 = dest(at: destDirA)
        let d2 = dest(at: destDirB)
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [d1, d2],
                        sharedRead: false, notifications: .silent)
        XCTAssertTrue(runner.isPreventingSleep,
                      "startAll must acquire the assertion synchronously too")
        await runner.waitForCompletion()
        XCTAssertFalse(runner.isPreventingSleep)
    }

    func test_sleepAssertion_isReleasedAfterCancelAll() async throws {
        // Regression for "make sure to clean all sleep prevention on cancel
        // or folder close". Folder-close routes through cancelAll() before
        // closing the shoot (see ContentView.closeShootGuarded), so the
        // cancelAll path is the canonical "release everything" guarantee.
        let p = try makePair("X")
        let d1 = dest(at: destDirA)
        let d2 = dest(at: destDirB)
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [d1, d2],
                        sharedRead: false, notifications: .silent)
        XCTAssertTrue(runner.isPreventingSleep)
        runner.cancelAll()
        await runner.waitForCompletion()
        XCTAssertFalse(runner.isPreventingSleep,
                       "assertion must be released even when the batch was cancelled")
    }

    func test_sleepAssertion_isReleasedAfterCancelOne() async throws {
        let p = try makePair("X")
        let d = dest(at: destDirA)
        runner.startOne(d.id, entries: [p], entryXMPs: [:],
                        projectName: "P", destination: d, notifications: .silent)
        XCTAssertTrue(runner.isPreventingSleep)
        runner.cancel(d.id)
        await runner.waitForCompletion()
        XCTAssertFalse(runner.isPreventingSleep,
                       "cancel(_:) for the only running destination releases the assertion")
    }

    func test_sleepAssertion_isReleasedAfterMkdirFailure() async throws {
        // Force the runner into the .failed code path by pointing at a
        // destination path that can't possibly be created (a file, not a
        // directory). The early-exit must still release the assertion.
        let p = try makePair("X")
        let bogus = sourceDir.appendingPathComponent("not-a-directory.txt")
        try Data("blocked".utf8).write(to: bogus)   // path now refers to a file
        let d = dest(at: bogus.appendingPathComponent("sub"))

        runner.startOne(d.id, entries: [p], entryXMPs: [:],
                        projectName: "P", destination: d, notifications: .silent)
        XCTAssertTrue(runner.isPreventingSleep)
        await runner.waitForCompletion()
        XCTAssertFalse(runner.isPreventingSleep,
                       "assertion must be released even when the run failed at mkdir")
    }

    func test_summary_recordsCopiedAndSkippedOnRerun() async throws {
        let p = try makePair("X")
        let d = dest(at: destDirA)
        runner.startOne(d.id, entries: [p], entryXMPs: [:],
                        projectName: "P", destination: d, notifications: .silent)
        await runner.waitForCompletion()

        // Second run — files should now be skipped.
        runner.startOne(d.id, entries: [p], entryXMPs: [:],
                        projectName: "P", destination: d, notifications: .silent)
        await runner.waitForCompletion()
        guard case .done(let s) = runner.perDestination[d.id] else {
            return XCTFail("expected .done after re-run")
        }
        XCTAssertEqual(s.copied, 0)
        XCTAssertEqual(s.skipped, 2)
    }
}
