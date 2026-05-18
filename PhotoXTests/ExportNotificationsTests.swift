import XCTest
@testable import PhotoX

/// Coverage for which notifications get posted (and which are deliberately
/// skipped). Uses a recording `ExportNotificationsAdapter` instead of the
/// real UNUserNotificationCenter — the production wrapper is small and
/// dispatches the real notification on the main actor.
@MainActor
final class ExportNotificationsTests: XCTestCase {

    private var tmpRoot: URL!
    private var sourceDir: URL!
    private var dest1: URL!
    private var dest2: URL!
    private var dest3: URL!
    private var runner: ExportRunner!

    /// Records every notification the runner emits, in order.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var perDestination: [(UUID, ExportRunner.Summary)] = []
        private(set) var allComplete: [[(UUID, ExportRunner.Summary)]] = []

        func recordDest(_ dest: ExportSettings.Destination, summary: ExportRunner.Summary) {
            lock.lock(); defer { lock.unlock() }
            perDestination.append((dest.id, summary))
        }

        func recordAll(_ summaries: [(ExportSettings.Destination, ExportRunner.Summary)]) {
            lock.lock(); defer { lock.unlock() }
            allComplete.append(summaries.map { ($0.0.id, $0.1) })
        }

        func adapter() -> ExportNotificationsAdapter {
            let recorder = self
            return ExportNotificationsAdapter(
                postDestinationComplete: { dest, summary in
                    recorder.recordDest(dest, summary: summary)
                },
                postAllComplete: { summaries in
                    recorder.recordAll(summaries)
                }
            )
        }
    }

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("photox-notif-tests-\(UUID().uuidString)")
        sourceDir = tmpRoot.appendingPathComponent("src")
        dest1 = tmpRoot.appendingPathComponent("d1")
        dest2 = tmpRoot.appendingPathComponent("d2")
        dest3 = tmpRoot.appendingPathComponent("d3")
        for dir in [sourceDir, dest1, dest2, dest3] {
            try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        }
        runner = ExportRunner()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func makePair() throws -> PhotoPair {
        let arw = sourceDir.appendingPathComponent("X.ARW")
        let hif = sourceDir.appendingPathComponent("X.HIF")
        try Data([1, 2, 3]).write(to: arw)
        try Data([4, 5, 6]).write(to: hif)
        return PhotoPair(rawURL: arw, heifURL: hif, stem: "X")
    }

    // MARK: tests

    func test_startOne_postsOneCompletionAndNoAllComplete() async throws {
        let p = try makePair()
        let d = ExportSettings.Destination(path: dest1.path)
        let recorder = Recorder()
        runner.startOne(d.id, pairs: [p], pairXMPs: [:],
                        projectName: "P", destination: d,
                        notifications: recorder.adapter())
        await runner.waitForCompletion()

        XCTAssertEqual(recorder.perDestination.count, 1)
        XCTAssertEqual(recorder.perDestination[0].0, d.id)
        XCTAssertTrue(recorder.allComplete.isEmpty,
                      "single-destination Run shouldn't fire 'all complete'")
    }

    func test_startAll_threeDestinations_emitsTwoPerDestPlusOneFinal() async throws {
        let p = try makePair()
        let d1 = ExportSettings.Destination(path: dest1.path)
        let d2 = ExportSettings.Destination(path: dest2.path)
        let d3 = ExportSettings.Destination(path: dest3.path)
        let recorder = Recorder()
        runner.startAll(pairs: [p], pairXMPs: [:],
                        projectName: "P", destinations: [d1, d2, d3],
                        sharedRead: false, notifications: recorder.adapter())
        await runner.waitForCompletion()

        // Per-destination notifications fire for the first N-1 destinations
        // (d1, d2). The last one (d3) is rolled into the "all complete".
        XCTAssertEqual(recorder.perDestination.count, 2)
        XCTAssertEqual(recorder.perDestination.map(\.0), [d1.id, d2.id])
        XCTAssertEqual(recorder.allComplete.count, 1)
        XCTAssertEqual(recorder.allComplete[0].count, 3,
                       "all-complete summary should include all 3 destinations")
    }

    func test_startAll_sharedRead_sameNotificationPattern() async throws {
        let p = try makePair()
        let d1 = ExportSettings.Destination(path: dest1.path)
        let d2 = ExportSettings.Destination(path: dest2.path)
        let recorder = Recorder()
        runner.startAll(pairs: [p], pairXMPs: [:],
                        projectName: "P", destinations: [d1, d2],
                        sharedRead: true, notifications: recorder.adapter())
        await runner.waitForCompletion()

        XCTAssertEqual(recorder.perDestination.count, 1, "first dest only")
        XCTAssertEqual(recorder.perDestination[0].0, d1.id)
        XCTAssertEqual(recorder.allComplete.count, 1)
    }

    func test_startAll_singleDestination_skipsPerDestAndOnlyAllComplete() async throws {
        let p = try makePair()
        let d1 = ExportSettings.Destination(path: dest1.path)
        let recorder = Recorder()
        runner.startAll(pairs: [p], pairXMPs: [:],
                        projectName: "P", destinations: [d1],
                        sharedRead: false, notifications: recorder.adapter())
        await runner.waitForCompletion()

        XCTAssertTrue(recorder.perDestination.isEmpty,
                      "with N=1 destinations, the only dest IS the last → skipped")
        XCTAssertEqual(recorder.allComplete.count, 1)
    }
}
