import XCTest
import CryptoKit
@testable import PhotoX

/// Mode B (shared-read) coverage: byte-identical output to Mode A,
/// single read per source file, skip logic still kicks in per destination.
@MainActor
final class ExportSharedReadTests: XCTestCase {

    private var tmpRoot: URL!
    private var sourceDir: URL!
    private var destA: URL!     // mode A run lands here
    private var destB1: URL!    // mode B run lands here (first dest)
    private var destB2: URL!    // mode B run lands here (second dest)
    private var runner: ExportRunner!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("photox-sharedread-tests-\(UUID().uuidString)")
        sourceDir = tmpRoot.appendingPathComponent("src")
        destA = tmpRoot.appendingPathComponent("dstA")
        destB1 = tmpRoot.appendingPathComponent("dstB1")
        destB2 = tmpRoot.appendingPathComponent("dstB2")
        for dir in [sourceDir, destA, destB1, destB2] {
            try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        }
        runner = ExportRunner()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func makePair(_ stem: String, body: String) throws -> PhotoEntry {
        let arw = sourceDir.appendingPathComponent("\(stem).ARW")
        let hif = sourceDir.appendingPathComponent("\(stem).HIF")
        let xmp = sourceDir.appendingPathComponent("\(stem).xmp")
        try "\(body)-ARW".data(using: .utf8)!.write(to: arw)
        try "\(body)-HIF".data(using: .utf8)!.write(to: hif)
        try "\(body)-XMP".data(using: .utf8)!.write(to: xmp)
        return PhotoEntry(rawURL: arw, previewURL: hif, stem: stem)
    }

    private func dest(at url: URL,
                      includeXMP: Bool = true) -> ExportPreset.Destination {
        // Tests intentionally re-run exports into the same
        // dest dir; the new per-row "Allow non-empty" gate
        // would otherwise block every second run.
        ExportPreset.Destination(path: url.path,
                                   includeXMP: includeXMP,
                                   allowNonEmpty: true)
    }

    private func hashes(in folder: URL) throws -> [String: String] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        var out: [String: String] = [:]
        for u in urls {
            let data = try Data(contentsOf: u)
            let digest = SHA256.hash(data: data)
            out[u.lastPathComponent] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    // MARK: tests

    func test_modeB_producesIdenticalBytesAsModeA_acrossDestinations() async throws {
        let p1 = try makePair("A", body: "alpha")
        let p2 = try makePair("B", body: "beta")
        let p3 = try makePair("C", body: "gamma")
        let pairs = [p1, p2, p3]

        // Mode A: run all destinations with sharedRead=false
        let dA = dest(at: destA)
        runner.startAll(entries: pairs, entryXMPs: [:],
                        projectName: "P", destinations: [dA],
                        sharedRead: false, notifications: .silent)
        await runner.waitForCompletion()

        // Mode B: run TWO destinations with sharedRead=true, then compare
        // each one's output against destA's.
        let runnerB = ExportRunner()
        let dB1 = dest(at: destB1)
        let dB2 = dest(at: destB2)
        runnerB.startAll(entries: pairs, entryXMPs: [:],
                         projectName: "P", destinations: [dB1, dB2],
                         sharedRead: true, notifications: .silent)
        await runnerB.waitForCompletion()

        let outA  = destA.appendingPathComponent("P")
        let outB1 = destB1.appendingPathComponent("P")
        let outB2 = destB2.appendingPathComponent("P")
        let hashA  = try hashes(in: outA)
        let hashB1 = try hashes(in: outB1)
        let hashB2 = try hashes(in: outB2)
        XCTAssertEqual(hashA, hashB1, "shared-read produced different bytes than per-dest loop")
        XCTAssertEqual(hashA, hashB2, "shared-read second destination got different bytes")
        XCTAssertEqual(hashA.count, 9, "expected 3 stems × 3 file types")
    }

    func test_modeB_skipsAcrossDestinations_whenAlreadyUpToDate() async throws {
        let p = try makePair("X", body: "hello")
        let dB1 = dest(at: destB1)
        let dB2 = dest(at: destB2)

        // First run: everything copies into both destinations.
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        // Second run: everything is already there → skipped on both.
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        guard case .done(let s1) = runner.perDestination[dB1.id],
              case .done(let s2) = runner.perDestination[dB2.id]
        else { return XCTFail("expected both destinations to be .done") }
        XCTAssertEqual(s1.copied, 0)
        XCTAssertEqual(s1.skipped, 3)
        XCTAssertEqual(s2.copied, 0)
        XCTAssertEqual(s2.skipped, 3)
    }

    func test_modeB_doesNotReadSource_whenAllDestinationsWouldSkip() async throws {
        // First run: copy a pair into both destinations normally.
        let p = try makePair("X", body: "hello")
        let dB1 = dest(at: destB1)
        let dB2 = dest(at: destB2)
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        // Make every source file UNREADABLE (chmod 0) so any attempted
        // read would error. The skip-first logic must short-circuit
        // before issuing Data(contentsOf:), or the test fails.
        let sourceFiles = [p.rawURL!, p.previewURL,
                           sourceDir.appendingPathComponent("X.xmp")]
        let fm = FileManager.default
        for u in sourceFiles {
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: u.path)
        }
        defer {
            // Restore permissions so the tmp dir can be cleaned in tearDown.
            for u in sourceFiles {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: u.path)
            }
        }

        // Re-run — every destination already has matching files; planner
        // should decide .skip everywhere and never attempt to read.
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        guard case .done(let s1) = runner.perDestination[dB1.id],
              case .done(let s2) = runner.perDestination[dB2.id]
        else { return XCTFail("expected both to be .done") }
        XCTAssertEqual(s1.copied, 0)
        XCTAssertEqual(s1.skipped, 3, "all three files must skip without a read")
        XCTAssertTrue(s1.errors.isEmpty,
                      "no errors expected — source must not have been read at all; got: \(s1.errors)")
        XCTAssertEqual(s2.copied, 0)
        XCTAssertEqual(s2.skipped, 3)
        XCTAssertTrue(s2.errors.isEmpty,
                      "no errors expected — source must not have been read at all; got: \(s2.errors)")
    }

    func test_modeB_perFileReadDecision_skipUntouchedReadOnlyChanged() async throws {
        // Two pairs (A, B) into two destinations. After a clean first run,
        // chmod every source to 0o000 EXCEPT A.ARW. Then delete A.ARW
        // from destB1 ONLY. On the second run:
        //   - A.ARW: dB1 needs write (deleted there), dB2 still has match.
        //     => writePlan non-empty → ONE read of A.ARW (succeeds).
        //   - A.HIF / A.xmp / B.*: every destination has a match
        //     => writePlan empty → NO read.
        // If the short-circuit regresses, those unreadable files will be
        // read and produce errors visible in the summaries.
        let pA = try makePair("A", body: "alpha")
        let pB = try makePair("B", body: "beta")
        let dB1 = dest(at: destB1)
        let dB2 = dest(at: destB2)
        runner.startAll(entries: [pA, pB], entryXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        try FileManager.default.removeItem(at: destB1.appendingPathComponent("P/A.ARW"))

        let fm = FileManager.default
        let unreadable = [pA.previewURL,
                          sourceDir.appendingPathComponent("A.xmp"),
                          pB.rawURL!, pB.previewURL,
                          sourceDir.appendingPathComponent("B.xmp")]
        for u in unreadable {
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: u.path)
        }
        defer {
            for u in unreadable {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: u.path)
            }
        }

        runner.startAll(entries: [pA, pB], entryXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        guard case .done(let s1) = runner.perDestination[dB1.id],
              case .done(let s2) = runner.perDestination[dB2.id]
        else { return XCTFail("expected both .done") }
        XCTAssertEqual(s1.copied, 1, "only A.ARW should re-copy on dB1")
        XCTAssertEqual(s1.skipped, 5, "everything else should skip without a read")
        XCTAssertTrue(s1.errors.isEmpty, "skipped files must not be read: \(s1.errors)")
        XCTAssertEqual(s2.copied, 0)
        XCTAssertEqual(s2.skipped, 6)
        XCTAssertTrue(s2.errors.isEmpty, "skipped files must not be read: \(s2.errors)")
    }

    func test_modeB_preservesSourceMtime_atEveryDestination() async throws {
        let p = try makePair("X", body: "hello")
        let pastMtime = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let xmpSrc = sourceDir.appendingPathComponent("X.xmp")
        for u in [p.rawURL!, p.previewURL, xmpSrc] {
            try FileManager.default.setAttributes(
                [.modificationDate: pastMtime], ofItemAtPath: u.path)
        }

        let dB1 = dest(at: destB1)
        let dB2 = dest(at: destB2)
        runner.startAll(entries: [p], entryXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        let outRoots: [URL] = [destB1, destB2]
        for outRoot in outRoots {
            for name in ["X.ARW", "X.HIF", "X.xmp"] {
                let path = outRoot.appendingPathComponent("P/\(name)").path
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                XCTAssertEqual(
                    attrs[.modificationDate] as? Date, pastMtime,
                    "shared-read mode must propagate source mtime to \(name) in \(outRoot.lastPathComponent)"
                )
            }
        }
    }

    func test_modeB_orphanPhase_runsPerDestinationStill() async throws {
        let pA = try makePair("A", body: "a")
        let pB = try makePair("B", body: "b")

        // Initial run: both pairs go into both destinations.
        let dB1 = dest(at: destB1)
        let dB2 = dest(at: destB2)
        runner.startAll(entries: [pA, pB], entryXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        // Now filter so only A is eligible, and enable orphan removal on dB1 only.
        let xmps: [String: XMPSidecar] = [
            "A": XMPSidecar(rating: 5),
            "B": XMPSidecar(rating: 1),
        ]
        let dB1Filtered = ExportPreset.Destination(
            path: destB1.path,
            showStars: [5], showRejected: false, showUnrated: false,
            allowNonEmpty: true, removeOrphans: true
        )
        let dB2Filtered = ExportPreset.Destination(
            path: destB2.path,
            showStars: [5], showRejected: false, showUnrated: false,
            allowNonEmpty: true, removeOrphans: false
        )
        runner.startAll(entries: [pA, pB], entryXMPs: xmps,
                        projectName: "P", destinations: [dB1Filtered, dB2Filtered],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: destB1.appendingPathComponent("P/B.ARW").path),
                       "dB1 should have B.ARW removed by orphan phase")
        XCTAssertTrue(fm.fileExists(atPath: destB2.appendingPathComponent("P/B.ARW").path),
                      "dB2 has removeOrphans=false; B.ARW must remain")
    }
}
