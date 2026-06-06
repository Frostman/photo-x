import XCTest
@testable import IndexingCore

final class SidecarRoundTripTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRoundTripPreservesEveryField() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exif = ExifSummary(
            camera: "Sony α1 II",
            lens: "FE 24-70mm F2.8 GM",
            shutterSpeed: "1/250",
            aperture: "f/2.8",
            iso: "ISO 400",
            focalLength: "50 mm",
            exposureCompensation: "+0.3 EV",
            dateTime: Date(timeIntervalSince1970: 1_700_000_000),
            orientation: 1,
            pixelWidth: 8640,
            pixelHeight: 5760
        )
        let afRegion = AFRegion(
            kind: .primaryFocus,
            rect: CGRect(x: 100, y: 200, width: 300, height: 400),
            label: "primary"
        )
        let afData = ExifToolRunner.AFData(
            regions: [afRegion],
            settings: AFSettings(focusMode: "AF-C",
                                 afAreaMode: "Wide",
                                 afTracking: "On",
                                 focusDistance: "2.3 m",
                                 pointsUsed: 5,
                                 focusFrameSize: "189 × 192")
        )

        let original = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(timeIntervalSince1970: 1_700_000_000),
            indexerVersion: "v0.1247.0-abc123def",
            entries: [
                "DSC04176": IndexEntry(
                    fingerprint: IndexFingerprint(size: 45_000_000,
                                                  mtimeNanos: 1_700_000_123_000_000_000),
                    exif: exif,
                    afData: afData,
                    sequenceNumber: 1,
                    thumbnailJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                    thumbnailOrientation: 6
                ),
                "DSC04177": IndexEntry(
                    fingerprint: IndexFingerprint(size: 12_345_678,
                                                  mtimeNanos: 1_700_000_124_500_000_000)
                ),
            ]
        )

        try SidecarWriter.write(original, to: tmp)
        let loaded = try XCTUnwrap(SidecarReader.load(at: tmp))
        XCTAssertEqual(loaded, original)
    }

    func testMissingFileReturnsNil() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(SidecarReader.load(at: tmp))
    }

    func testVersionMismatchReturnsNil() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bogus = ShootSidecarIndex(
            version: 999,
            indexedAt: Date(),
            indexerVersion: "test",
            entries: [:]
        )
        try SidecarWriter.write(bogus, to: tmp)
        XCTAssertNil(SidecarReader.load(at: tmp))
    }

    func testCorruptFileReturnsNil() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data("not a plist".utf8).write(to: SidecarFile.url(in: tmp))
        XCTAssertNil(SidecarReader.load(at: tmp))
    }

    func testWriteIsAtomic() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(timeIntervalSince1970: 1_000_000),
            indexerVersion: "v1",
            entries: ["A": IndexEntry(fingerprint: .init(size: 1, mtimeNanos: 1))]
        )
        try SidecarWriter.write(first, to: tmp)

        let second = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(timeIntervalSince1970: 2_000_000),
            indexerVersion: "v2",
            entries: ["B": IndexEntry(fingerprint: .init(size: 2, mtimeNanos: 2))]
        )
        try SidecarWriter.write(second, to: tmp)

        let loaded = try XCTUnwrap(SidecarReader.load(at: tmp))
        XCTAssertEqual(loaded.indexerVersion, "v2")
        XCTAssertNil(loaded.entries["A"])
        XCTAssertNotNil(loaded.entries["B"])
    }
}
