import XCTest
@testable import IndexingCore

/// Runs the coordinator against a real shoot folder pointed to by the
/// `PHOTOX_INDEXER_FIXTURE_DIR` env var and asserts the resulting
/// sidecar's shape. Skipped silently when the env var is unset so
/// `swift test` works on machines without sample files (e.g. CI).
///
/// Locally, point it at the repo's `sample/`:
///   PHOTOX_INDEXER_FIXTURE_DIR=/Users/.../photo-x/sample swift test
final class CoordinatorParityTests: XCTestCase {

    private var fixtureURL: URL? {
        guard let path = ProcessInfo.processInfo
                .environment["PHOTOX_INDEXER_FIXTURE_DIR"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Fingerprint equality tolerates up to 1 s of mtime drift
    /// (size must still match exactly). Pins the SMB/ext4-drift
    /// guarantee from `IndexFingerprint.==` — a future change that
    /// tightens this without thinking through SMB users will fail
    /// here visibly.
    func testFingerprintTolerates1sMtimeDrift() throws {
        // Within the tolerance window → equal.
        let a = IndexFingerprint(size: 100, mtimeNanos: 1_700_000_000_000_000_000)
        let b = IndexFingerprint(size: 100, mtimeNanos: 1_700_000_000_500_000_000)
        XCTAssertEqual(a, b, "500 ms drift must compare equal")

        let c = IndexFingerprint(size: 100, mtimeNanos: 1_700_000_001_000_000_000)
        XCTAssertEqual(a, c, "exactly 1 s drift must compare equal")

        // Outside the tolerance window → not equal.
        let d = IndexFingerprint(size: 100, mtimeNanos: 1_700_000_001_000_000_001)
        XCTAssertNotEqual(a, d, "1 s + 1 ns drift must compare unequal")

        // Size mismatch is always unequal regardless of mtime.
        let e = IndexFingerprint(size: 101, mtimeNanos: 1_700_000_000_000_000_000)
        XCTAssertNotEqual(a, e, "size mismatch must compare unequal")
    }

    func testFixtureFolderProducesNonEmptySidecar() async throws {
        guard let fixture = fixtureURL else {
            // Silently skipped; CI / dev opts in via env var.
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path),
                      "Fixture path \(fixture.path) does not exist")

        let coord = IndexingCoordinator(
            shootFolder: fixture,
            workerCount: 2,
            indexerVersion: "parity-test"
        )
        let sidecar = await coord.run()

        XCTAssertEqual(sidecar.version, ShootSidecarIndex.currentSchemaVersion)
        XCTAssertEqual(sidecar.indexerVersion, "parity-test")
        XCTAssertFalse(sidecar.entries.isEmpty,
                       "Fixture should contain at least one ARW+HIF / ARW+JPG / HIF / JPG entry")

        for (stem, entry) in sidecar.entries {
            XCTAssertGreaterThan(entry.fingerprint.size, 0,
                                 "\(stem): fingerprint.size must be > 0")
            XCTAssertGreaterThan(entry.fingerprint.mtimeNanos, 0,
                                 "\(stem): fingerprint.mtimeNanos must be > 0")
        }

        // At least one entry should have a thumbnail (the fast path
        // covers ~all Sony HEIF/JPG); if zero, something is broken.
        let withThumb = sidecar.entries.values.filter { $0.thumbnailJPEG != nil }.count
        XCTAssertGreaterThan(withThumb, 0,
                             "Expected at least one thumbnail extraction to succeed")
    }
}
