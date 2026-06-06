import XCTest
@testable import IndexingCore

/// Pins `ShootScanner.scan(folder:)` to populate `previewFingerprints`
/// and `xmpStems` from the same folder listing — the load-bearing
/// invariant that lets `ViewerState.loadShoot` skip every per-entry
/// stat over SMB. Regression here = shoot-open back to "minutes of
/// stat noise" on a NAS.
final class ShootScannerHarvestTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShootScannerHarvest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ name: String, bytes: Int = 64,
                           mtime: TimeInterval = 1_700_000_000) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: mtime)],
            ofItemAtPath: url.path)
        return url
    }

    // MARK: - previewFingerprints

    func test_scan_populatesPreviewFingerprints_forEveryEntry() throws {
        try writeFile("DSC00001.ARW", bytes: 1024)
        try writeFile("DSC00001.HIF", bytes: 2048, mtime: 1_700_000_000)
        try writeFile("DSC00002.JPG", bytes: 4096, mtime: 1_700_000_100)
        try writeFile("DSC00003.HIF", bytes: 8192, mtime: 1_700_000_200)

        let shoot = ShootScanner.scan(folder: tempDir)
        XCTAssertEqual(shoot.entries.count, 3,
                       "ARW+HIF pair counts as one entry")
        XCTAssertEqual(shoot.previewFingerprints.count, 3,
                       "every entry must have a harvested fingerprint")

        XCTAssertEqual(shoot.previewFingerprints["DSC00001"]?.size, 2048,
                       "HIF size for ARW+HIF pair (preview = HIF)")
        XCTAssertEqual(shoot.previewFingerprints["DSC00002"]?.size, 4096)
        XCTAssertEqual(shoot.previewFingerprints["DSC00003"]?.size, 8192)
    }

    func test_scan_previewFingerprints_matchPerFileFingerprint() throws {
        try writeFile("DSC00010.HIF", bytes: 12345, mtime: 1_700_000_500.7)

        let shoot = ShootScanner.scan(folder: tempDir)
        let harvested = try XCTUnwrap(shoot.previewFingerprints["DSC00010"])
        let perFile = try IndexingCoordinator.fingerprint(of:
            tempDir.appendingPathComponent("DSC00010.HIF"))

        XCTAssertEqual(harvested, perFile,
                       "fingerprint harvested during scan must equal per-file fingerprint")
    }

    // MARK: - xmpStems

    func test_scan_populatesXmpStems_forSiblingXmps() throws {
        try writeFile("DSC00100.HIF")
        try writeFile("DSC00100.xmp")
        try writeFile("DSC00101.HIF")
        // DSC00101 has NO xmp companion
        try writeFile("DSC00102.JPG")
        try writeFile("DSC00102.xmp")

        let shoot = ShootScanner.scan(folder: tempDir)
        XCTAssertEqual(shoot.xmpStems, ["DSC00100", "DSC00102"],
                       "only stems with a matching .xmp sibling appear")
    }

    func test_scan_xmpStems_ignoresOrphanXmps() throws {
        try writeFile("DSC00200.HIF")
        try writeFile("DSC00200.xmp")
        // Orphan: xmp with no matching photo entry
        try writeFile("DSC99999.xmp")

        let shoot = ShootScanner.scan(folder: tempDir)
        XCTAssertEqual(shoot.xmpStems, ["DSC00200"],
                       "orphan .xmp (no matching photo) must not appear")
        XCTAssertFalse(shoot.xmpStems.contains("DSC99999"))
    }

    func test_scan_xmpStems_matchesCaseInsensitiveExtension() throws {
        try writeFile("DSC00300.HIF")
        try writeFile("DSC00300.XMP")   // uppercase ext

        let shoot = ShootScanner.scan(folder: tempDir)
        XCTAssertTrue(shoot.xmpStems.contains("DSC00300"),
                      ".XMP (uppercase) must be detected just like .xmp")
    }

    // MARK: - empty folder

    func test_scan_emptyFolder_emptyAll() throws {
        let shoot = ShootScanner.scan(folder: tempDir)
        XCTAssertTrue(shoot.entries.isEmpty)
        XCTAssertTrue(shoot.previewFingerprints.isEmpty)
        XCTAssertTrue(shoot.xmpStems.isEmpty)
    }
}
