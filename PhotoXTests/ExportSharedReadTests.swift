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

    private func makePair(_ stem: String, body: String) throws -> PhotoPair {
        let arw = sourceDir.appendingPathComponent("\(stem).ARW")
        let hif = sourceDir.appendingPathComponent("\(stem).HIF")
        let xmp = sourceDir.appendingPathComponent("\(stem).xmp")
        try "\(body)-ARW".data(using: .utf8)!.write(to: arw)
        try "\(body)-HIF".data(using: .utf8)!.write(to: hif)
        try "\(body)-XMP".data(using: .utf8)!.write(to: xmp)
        return PhotoPair(rawURL: arw, heifURL: hif, stem: stem)
    }

    private func dest(at url: URL,
                      includeXMP: Bool = true) -> ExportSettings.Destination {
        ExportSettings.Destination(path: url.path, includeXMP: includeXMP)
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
        runner.startAll(pairs: pairs, pairXMPs: [:],
                        projectName: "P", destinations: [dA],
                        sharedRead: false, notifications: .silent)
        await runner.waitForCompletion()

        // Mode B: run TWO destinations with sharedRead=true, then compare
        // each one's output against destA's.
        let runnerB = ExportRunner()
        let dB1 = dest(at: destB1)
        let dB2 = dest(at: destB2)
        runnerB.startAll(pairs: pairs, pairXMPs: [:],
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
        runner.startAll(pairs: [p], pairXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        // Second run: everything is already there → skipped on both.
        runner.startAll(pairs: [p], pairXMPs: [:],
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

    func test_modeB_orphanPhase_runsPerDestinationStill() async throws {
        let pA = try makePair("A", body: "a")
        let pB = try makePair("B", body: "b")

        // Initial run: both pairs go into both destinations.
        let dB1 = dest(at: destB1)
        let dB2 = dest(at: destB2)
        runner.startAll(pairs: [pA, pB], pairXMPs: [:],
                        projectName: "P", destinations: [dB1, dB2],
                        sharedRead: true, notifications: .silent)
        await runner.waitForCompletion()

        // Now filter so only A is eligible, and enable orphan removal on dB1 only.
        let xmps: [String: XMPSidecar] = [
            "A": XMPSidecar(rating: 5),
            "B": XMPSidecar(rating: 1),
        ]
        let dB1Filtered = ExportSettings.Destination(
            path: destB1.path,
            showStars: [5], showRejected: false, showUnrated: false,
            removeOrphans: true
        )
        let dB2Filtered = ExportSettings.Destination(
            path: destB2.path,
            showStars: [5], showRejected: false, showUnrated: false,
            removeOrphans: false
        )
        runner.startAll(pairs: [pA, pB], pairXMPs: xmps,
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
