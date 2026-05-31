import XCTest
@testable import PhotoX

/// Realistic end-to-end coverage for the per-destination copy loop.
/// Builds throwaway source + destination dirs on disk for each test —
/// exercises the genuine FileManager.copyItem / removeItem code path,
/// not just the planning logic.
@MainActor
final class ExportCopyLoopTests: XCTestCase {

    private var tmpRoot: URL!
    private var sourceDir: URL!
    private var destDir: URL!
    private var runner: ExportRunner!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("photox-export-tests-\(UUID().uuidString)")
        sourceDir = tmpRoot.appendingPathComponent("src", isDirectory: true)
        destDir = tmpRoot.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        runner = ExportRunner()  // fresh instance per test, not the shared one
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil; sourceDir = nil; destDir = nil; runner = nil
    }

    // MARK: source builders

    /// Creates ARW/HIF/XMP files for stem with given body bytes; returns the
    /// resulting PhotoEntry.
    @discardableResult
    private func makePair(stem: String, arwBytes: Int = 1024, hifBytes: Int = 512,
                          xmp: String? = "<xmpmeta/>") throws -> PhotoEntry {
        let arw = sourceDir.appendingPathComponent("\(stem).ARW")
        let hif = sourceDir.appendingPathComponent("\(stem).HIF")
        try Data(repeating: 0xAB, count: arwBytes).write(to: arw)
        try Data(repeating: 0xCD, count: hifBytes).write(to: hif)
        if let xmp {
            let xmpURL = sourceDir.appendingPathComponent("\(stem).xmp")
            try xmp.data(using: .utf8)!.write(to: xmpURL)
        }
        return PhotoEntry(rawURL: arw, previewURL: hif, stem: stem)
    }

    private func destination(
        showStars: Set<Int> = [1,2,3,4,5],
        showRejected: Bool = true,
        showUnrated: Bool = true,
        includeARW: Bool = true,
        includeHIF: Bool = true,
        includeXMP: Bool = true,
        overwrite: ExportSettings.OverwritePolicy = .skipUnchangedElseOverwrite,
        removeOrphans: Bool = false
    ) -> ExportSettings.Destination {
        ExportSettings.Destination(
            path: destDir.path,
            showStars: showStars,
            showRejected: showRejected,
            showUnrated: showUnrated,
            includeARW: includeARW, includeHIF: includeHIF, includeXMP: includeXMP,
            overwrite: overwrite,
            // Tests intentionally re-run exports into the same
            // dest dir; the new per-row "Allow non-empty" gate
            // would otherwise block every second run.
            allowNonEmpty: true,
            removeOrphans: removeOrphans
        )
    }

    private func outputFolder(project: String) -> URL {
        destDir.appendingPathComponent(project, isDirectory: true)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func run(_ dest: ExportSettings.Destination, entries: [PhotoEntry],
                     entryXMPs: [String: XMPSidecar] = [:],
                     project: String = "P") async {
        runner.startOne(dest.id, entries: entries, entryXMPs: entryXMPs,
                        projectName: project, destination: dest,
                        notifications: .silent)
        await runner.waitForCompletion()
    }

    private func summary(_ destID: UUID) -> ExportRunner.Summary? {
        switch runner.perDestination[destID] {
        case .done(let s), .cancelled(let s): return s
        case .failed(_, let s?): return s
        default: return nil
        }
    }

    // MARK: tests

    func test_copy_emptyDestination_copiesAllMatchingPairs() async throws {
        let p1 = try makePair(stem: "DSC0001")
        let p2 = try makePair(stem: "DSC0002")
        let dest = destination()
        await run(dest, entries: [p1, p2])

        let out = outputFolder(project: "P")
        XCTAssertTrue(exists(out.appendingPathComponent("DSC0001.ARW")))
        XCTAssertTrue(exists(out.appendingPathComponent("DSC0001.HIF")))
        XCTAssertTrue(exists(out.appendingPathComponent("DSC0001.xmp")))
        XCTAssertTrue(exists(out.appendingPathComponent("DSC0002.ARW")))
        XCTAssertEqual(summary(dest.id)?.copied, 6) // 3 files × 2 pairs
        XCTAssertEqual(summary(dest.id)?.skipped, 0)
    }

    func test_copy_respectsStarFilter() async throws {
        let p1 = try makePair(stem: "DSC0001")
        let p2 = try makePair(stem: "DSC0002")
        let xmps: [String: XMPSidecar] = [
            "DSC0001": XMPSidecar(rating: 5),
            "DSC0002": XMPSidecar(rating: 3),
        ]
        let dest = destination(showStars: [5], showRejected: false, showUnrated: false)
        await run(dest, entries: [p1, p2], entryXMPs: xmps)
        let out = outputFolder(project: "P")
        XCTAssertTrue(exists(out.appendingPathComponent("DSC0001.ARW")))
        XCTAssertFalse(exists(out.appendingPathComponent("DSC0002.ARW")))
    }

    func test_copy_respectsRejectedAndUnratedFilters() async throws {
        let pR = try makePair(stem: "REJ")
        let pU = try makePair(stem: "UNR")
        let xmps: [String: XMPSidecar] = ["REJ": XMPSidecar(rating: -1)]
        let dest = destination(showStars: [], showRejected: true, showUnrated: false)
        await run(dest, entries: [pR, pU], entryXMPs: xmps)
        let out = outputFolder(project: "P")
        XCTAssertTrue(exists(out.appendingPathComponent("REJ.ARW")))
        XCTAssertFalse(exists(out.appendingPathComponent("UNR.ARW")))
    }

    func test_copy_respectsTypeToggles() async throws {
        let p = try makePair(stem: "DSC0001")
        let dest = destination(includeXMP: false)
        await run(dest, entries: [p])
        let out = outputFolder(project: "P")
        XCTAssertTrue(exists(out.appendingPathComponent("DSC0001.ARW")))
        XCTAssertTrue(exists(out.appendingPathComponent("DSC0001.HIF")))
        XCTAssertFalse(exists(out.appendingPathComponent("DSC0001.xmp")),
                       "XMP should not be copied when includeXMP=false")
    }

    func test_copy_projectSubfolder_isCreated() async throws {
        let p = try makePair(stem: "X")
        let dest = destination()
        await run(dest, entries: [p], project: "Wedding 2026")
        XCTAssertTrue(exists(destDir.appendingPathComponent("Wedding 2026/X.ARW")))
    }

    func test_copy_emptyProjectName_landsInDestRoot() async throws {
        let p = try makePair(stem: "X")
        let dest = destination()
        await run(dest, entries: [p], project: "")
        XCTAssertTrue(exists(destDir.appendingPathComponent("X.ARW")))
        XCTAssertFalse(exists(destDir.appendingPathComponent("X")),
                       "no subfolder named after the (empty) project")
    }

    func test_copy_secondRun_skipsUnchanged() async throws {
        let p = try makePair(stem: "X")
        let dest = destination()
        await run(dest, entries: [p])
        let firstSummary = summary(dest.id)!
        XCTAssertEqual(firstSummary.copied, 3)
        XCTAssertEqual(firstSummary.skipped, 0)

        await run(dest, entries: [p])
        let secondSummary = summary(dest.id)!
        XCTAssertEqual(secondSummary.copied, 0)
        XCTAssertEqual(secondSummary.skipped, 3)
    }

    func test_copy_diffSize_overwrites_perDefaultPolicy() async throws {
        let p = try makePair(stem: "X", arwBytes: 100)
        let dest = destination()
        await run(dest, entries: [p])

        // Bigger source on a second run → must overwrite.
        try FileManager.default.removeItem(at: p.rawURL!)
        try Data(repeating: 0xEE, count: 500).write(to: p.rawURL!)

        await run(dest, entries: [p])
        let bytes = try bytes(outputFolder(project: "P").appendingPathComponent("X.ARW"))
        XCTAssertEqual(bytes.count, 500)
    }

    func test_copy_skipIfExists_neverOverwrites() async throws {
        let p = try makePair(stem: "X", arwBytes: 100)
        let dest = destination(overwrite: .skipIfExists)
        await run(dest, entries: [p])

        try FileManager.default.removeItem(at: p.rawURL!)
        try Data(repeating: 0xEE, count: 500).write(to: p.rawURL!)

        await run(dest, entries: [p])
        let bytes = try bytes(outputFolder(project: "P").appendingPathComponent("X.ARW"))
        XCTAssertEqual(bytes.count, 100, "skipIfExists must keep the original 100 bytes")
        XCTAssertEqual(summary(dest.id)?.skipped, 3)
        XCTAssertEqual(summary(dest.id)?.copied, 0)
    }

    func test_copy_xmp_destNewer_isNeverRegressed_evenWithAlwaysOverwrite() async throws {
        let p = try makePair(stem: "X")
        let dest = destination(overwrite: .alwaysOverwrite)
        await run(dest, entries: [p])

        // Force the destination XMP to be 1 hour in the future.
        let dstXMP = outputFolder(project: "P").appendingPathComponent("X.xmp")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: dstXMP.path
        )
        let futureContent = "FUTURE"
        try futureContent.data(using: .utf8)!.write(to: dstXMP)
        // Re-set mtime since write() resets it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: dstXMP.path
        )

        // Re-run the source XMP (mtime ≈ now) into the same destination.
        await run(dest, entries: [p])

        let body = try String(contentsOf: dstXMP, encoding: .utf8)
        XCTAssertEqual(body, "FUTURE", "future destination XMP must not be overwritten")
    }

    func test_removeOrphans_deletesPairsThatFellOut() async throws {
        let pA = try makePair(stem: "A")
        let pB = try makePair(stem: "B")
        // First run includes both A and B.
        let dest1 = destination(removeOrphans: false)
        await run(dest1, entries: [pA, pB])
        XCTAssertTrue(exists(outputFolder(project: "P").appendingPathComponent("A.ARW")))
        XCTAssertTrue(exists(outputFolder(project: "P").appendingPathComponent("B.ARW")))

        // Second run only A passes the filter, with orphan removal on.
        let xmps: [String: XMPSidecar] = [
            "A": XMPSidecar(rating: 5),
            "B": XMPSidecar(rating: 1),
        ]
        let dest2 = destination(showStars: [5], showRejected: false, showUnrated: false,
                                removeOrphans: true)
        await run(dest2, entries: [pA, pB], entryXMPs: xmps)
        XCTAssertTrue(exists(outputFolder(project: "P").appendingPathComponent("A.ARW")))
        XCTAssertFalse(exists(outputFolder(project: "P").appendingPathComponent("B.ARW")),
                       "orphaned B should be deleted")
        XCTAssertFalse(exists(outputFolder(project: "P").appendingPathComponent("B.HIF")))
        XCTAssertFalse(exists(outputFolder(project: "P").appendingPathComponent("B.xmp")))
        XCTAssertEqual(summary(dest2.id)?.deleted, 3, "expected 3 deletions (ARW/HIF/XMP)")
    }

    func test_removeOrphans_doesNotDeleteForeignFiles() async throws {
        let pA = try makePair(stem: "A")
        let out = outputFolder(project: "P")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let foreign = out.appendingPathComponent("notes.txt")
        try "do not delete me".data(using: .utf8)!.write(to: foreign)

        let dest = destination(removeOrphans: true)
        await run(dest, entries: [pA])
        XCTAssertTrue(exists(foreign), "foreign txt file should survive orphan removal")
    }

    func test_atomicCopy_leavesNoTempFileBehind_afterSuccessfulRun() async throws {
        let p1 = try makePair(stem: "A")
        let p2 = try makePair(stem: "B")
        let dest = destination()
        await run(dest, entries: [p1, p2])

        let out = outputFolder(project: "P")
        let contents = try FileManager.default.contentsOfDirectory(
            at: out, includingPropertiesForKeys: nil)
        let tempFiles = contents.filter { $0.lastPathComponent.contains(".photox-") }
        XCTAssertTrue(tempFiles.isEmpty,
                      "atomic copy must clean up its temp files; found \(tempFiles)")
    }

    func test_atomicCopy_preservesSourceMtime_atDestination() async throws {
        // Set source mtime to a known time in the past.
        let p = try makePair(stem: "X")
        let pastMtime = Date(timeIntervalSinceReferenceDate: 1_000_000)  // arbitrary past
        for url in [p.rawURL!, p.previewURL,
                    sourceDir.appendingPathComponent("X.xmp")] {
            try FileManager.default.setAttributes(
                [.modificationDate: pastMtime], ofItemAtPath: url.path)
        }

        let dest = destination()
        await run(dest, entries: [p])

        // Each copied file at the destination must carry the SOURCE mtime,
        // not "now". Without that, the universal skip-if-same-size-and-mtime
        // check would re-copy unchanged files on the next run.
        let out = outputFolder(project: "P")
        for name in ["X.ARW", "X.HIF", "X.xmp"] {
            let attrs = try FileManager.default.attributesOfItem(
                atPath: out.appendingPathComponent(name).path)
            let destMtime = attrs[.modificationDate] as? Date
            XCTAssertEqual(destMtime, pastMtime,
                           "\(name) dest mtime must equal source mtime, got \(String(describing: destMtime))")
        }
    }

    func test_atomicCopy_overwriteIsAtomic_destNeverMissing() async throws {
        // Two runs against the same destination — second run overwrites.
        // After both, the destination must contain the new bytes; at no
        // point should there be a missing file (regression test for the
        // previous removeItem-then-copyItem pattern that briefly left
        // the destination absent).
        let p = try makePair(stem: "X", arwBytes: 100)
        let dest = destination()
        await run(dest, entries: [p])

        // Bigger source for the second run; the existing dest will be
        // atomically replaced.
        try FileManager.default.removeItem(at: p.rawURL!)
        try Data(repeating: 0xFA, count: 700).write(to: p.rawURL!)
        await run(dest, entries: [p])

        let destFile = outputFolder(project: "P").appendingPathComponent("X.ARW")
        let body = try bytes(destFile)
        XCTAssertEqual(body.count, 700)
        XCTAssertEqual(body.first, 0xFA)
    }

    func test_handlesMissingXMP_gracefully() async throws {
        let p = try makePair(stem: "X", xmp: nil)   // no XMP sidecar
        let dest = destination()
        await run(dest, entries: [p])
        XCTAssertTrue(exists(outputFolder(project: "P").appendingPathComponent("X.ARW")))
        XCTAssertFalse(exists(outputFolder(project: "P").appendingPathComponent("X.xmp")))
        XCTAssertEqual(summary(dest.id)?.errors.count, 0)
        XCTAssertEqual(summary(dest.id)?.copied, 2, "no XMP to copy — only ARW + HIF")
    }

    /// Regression: ARW+JPG entries (no HIF) must export the JPG when
    /// the "HIF/JPG" toggle is on. The export pipeline routes through
    /// `entry.previewURL` regardless of format, so HIF and JPG are
    /// peers all the way through planner → runner → orphan-prune.
    func test_copy_ARWplusJPG_exportsJPGUnderHIFToggle() async throws {
        // Build an ARW+JPG entry by hand — the existing makePair
        // helper assumes HIF. We construct the JPG sibling directly,
        // then point `previewURL` at it.
        let stem = "DSC00060"
        let arw = sourceDir.appendingPathComponent("\(stem).ARW")
        let jpg = sourceDir.appendingPathComponent("\(stem).JPG")
        try Data(repeating: 0xAB, count: 1024).write(to: arw)
        try Data(repeating: 0xCD, count: 512).write(to: jpg)
        let entry = PhotoEntry(rawURL: arw, previewURL: jpg, stem: stem)

        let dest = destination(includeXMP: false)
        await run(dest, entries: [entry])

        let out = outputFolder(project: "P")
        XCTAssertTrue(exists(out.appendingPathComponent("\(stem).ARW")),
                      "ARW should be copied when includeARW=true")
        XCTAssertTrue(exists(out.appendingPathComponent("\(stem).JPG")),
                      "JPG (entry.previewURL) should be copied under the single HIF/JPG toggle")
        XCTAssertFalse(exists(out.appendingPathComponent("\(stem).HIF")),
                       "no HIF in source — none should appear in output")
    }
}
