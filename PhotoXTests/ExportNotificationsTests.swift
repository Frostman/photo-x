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
        private(set) var allComplete: [[(UUID, ExportRunner.Summary)]] = []

        func recordAll(_ summaries: [(ExportPreset.Destination, ExportRunner.Summary)]) {
            lock.lock(); defer { lock.unlock() }
            allComplete.append(summaries.map { ($0.0.id, $0.1) })
        }

        func adapter() -> ExportNotificationsAdapter {
            let recorder = self
            return ExportNotificationsAdapter(
                postAllComplete: { summaries in recorder.recordAll(summaries) }
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

    private func makePair() throws -> PhotoEntry {
        let arw = sourceDir.appendingPathComponent("X.ARW")
        let hif = sourceDir.appendingPathComponent("X.HIF")
        try Data([1, 2, 3]).write(to: arw)
        try Data([4, 5, 6]).write(to: hif)
        return PhotoEntry(rawURL: arw, previewURL: hif, stem: "X")
    }

    // MARK: tests

    func test_startOne_postsOneSummaryNotification() async throws {
        let p = try makePair()
        let d = ExportPreset.Destination(path: dest1.path)
        let recorder = Recorder()
        runner.startOne(d.id, entries: [p], entryXMPs: [:],
                        projectName: "P", destination: d,
                        notifications: recorder.adapter())
        await runner.waitForCompletion()

        XCTAssertEqual(recorder.allComplete.count, 1,
                       "per-row Run also fires exactly one summary notification")
        XCTAssertEqual(recorder.allComplete[0].count, 1)
        XCTAssertEqual(recorder.allComplete[0][0].0, d.id)
    }

    func test_startAll_emitsExactlyOneSummary_regardlessOfDestCount() async throws {
        let p = try makePair()
        let d1 = ExportPreset.Destination(path: dest1.path)
        let d2 = ExportPreset.Destination(path: dest2.path)
        let d3 = ExportPreset.Destination(path: dest3.path)
        let recorder = Recorder()
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [d1, d2, d3],
                        sharedRead: false, notifications: recorder.adapter())
        await runner.waitForCompletion()

        XCTAssertEqual(recorder.allComplete.count, 1,
                       "exactly one summary notification per batch — no per-destination noise")
        XCTAssertEqual(recorder.allComplete[0].count, 3,
                       "summary should cover all 3 destinations")
    }

    func test_startAll_sharedRead_sameOneSummaryContract() async throws {
        let p = try makePair()
        let d1 = ExportPreset.Destination(path: dest1.path)
        let d2 = ExportPreset.Destination(path: dest2.path)
        let recorder = Recorder()
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [d1, d2],
                        sharedRead: true, notifications: recorder.adapter())
        await runner.waitForCompletion()

        XCTAssertEqual(recorder.allComplete.count, 1)
        XCTAssertEqual(recorder.allComplete[0].count, 2)
    }
}
