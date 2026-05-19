import XCTest
@testable import PhotoX

/// Pure-fn + integration coverage for VolumeScanner. The DCIM-name
/// matcher is trivially testable; the full scan is exercised against a
/// synthetic temp tree via the `findCardFolders(volumesRoot:)` seam so
/// we don't depend on a real mounted card.
final class VolumeScannerTests: XCTestCase {

    // MARK: isDCIMConventionName

    func test_isDCIMConventionName_acceptsSonyDefault() {
        XCTAssertTrue(VolumeScanner.isDCIMConventionName("100MSDCF"))
        XCTAssertTrue(VolumeScanner.isDCIMConventionName("101MSDCF"))
        XCTAssertTrue(VolumeScanner.isDCIMConventionName("999MSDCF"))
    }

    func test_isDCIMConventionName_acceptsOtherVendors() {
        XCTAssertTrue(VolumeScanner.isDCIMConventionName("100ANDRO"))
        XCTAssertTrue(VolumeScanner.isDCIMConventionName("100GOPRO"))
        XCTAssertTrue(VolumeScanner.isDCIMConventionName("100APPLE"))
    }

    func test_isDCIMConventionName_acceptsBareThreeDigits() {
        XCTAssertTrue(VolumeScanner.isDCIMConventionName("100"))
        XCTAssertTrue(VolumeScanner.isDCIMConventionName("042"))
    }

    func test_isDCIMConventionName_rejectsNonDigitPrefix() {
        XCTAssertFalse(VolumeScanner.isDCIMConventionName("MISC"))
        XCTAssertFalse(VolumeScanner.isDCIMConventionName("Thumbnails"))
        XCTAssertFalse(VolumeScanner.isDCIMConventionName("X100MSDCF"))
    }

    func test_isDCIMConventionName_rejectsTooShort() {
        XCTAssertFalse(VolumeScanner.isDCIMConventionName(""))
        XCTAssertFalse(VolumeScanner.isDCIMConventionName("1"))
        XCTAssertFalse(VolumeScanner.isDCIMConventionName("99"))
    }

    func test_isDCIMConventionName_rejectsDigitMixedIntoPrefix() {
        XCTAssertFalse(VolumeScanner.isDCIMConventionName("1A0MSDCF"))
        XCTAssertFalse(VolumeScanner.isDCIMConventionName("10AMSDCF"))
    }

    // MARK: findCardFolders against a temp tree

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photox-volscan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    /// Helper: build `<tmpRoot>/<card>/DCIM/<folder>/<stem>.<ext>` files.
    private func write(card: String, folder: String, stem: String, ext: String) throws {
        let dir = tmpRoot
            .appendingPathComponent(card)
            .appendingPathComponent("DCIM")
            .appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(stem).\(ext)")
        try Data().write(to: file)
    }

    /// Helper: ensure an empty subdir exists.
    private func mkdir(card: String, folder: String) throws {
        let dir = tmpRoot
            .appendingPathComponent(card)
            .appendingPathComponent("DCIM")
            .appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func test_findCardFolders_returnsPairedDCIMFolders() throws {
        // A single card with one fully-paired roll.
        try write(card: "MyCard", folder: "100MSDCF", stem: "DSC0001", ext: "ARW")
        try write(card: "MyCard", folder: "100MSDCF", stem: "DSC0001", ext: "HIF")

        let found = VolumeScanner.findCardFolders(volumesRoot: tmpRoot.path)
        // Use hasSuffix to tolerate macOS's /var → /private/var symlink
        // resolution that FileManager.contentsOfDirectory applies.
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].hasSuffix("/MyCard/DCIM/100MSDCF"))
    }

    func test_findCardFolders_skipsFoldersWithoutDCIMPrefix() throws {
        // Sony A1 II sometimes writes a `MISC` sibling. It shouldn't show up.
        try write(card: "MyCard", folder: "100MSDCF", stem: "DSC0001", ext: "ARW")
        try write(card: "MyCard", folder: "100MSDCF", stem: "DSC0001", ext: "HIF")
        try write(card: "MyCard", folder: "MISC",     stem: "DSC0001", ext: "ARW")
        try write(card: "MyCard", folder: "MISC",     stem: "DSC0001", ext: "HIF")

        let found = VolumeScanner.findCardFolders(volumesRoot: tmpRoot.path)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].hasSuffix("/100MSDCF"))
    }

    func test_findCardFolders_skipsEmptyOrUnpairedSubfolders() throws {
        try write(card: "MyCard", folder: "100MSDCF", stem: "DSC0001", ext: "ARW")
        try write(card: "MyCard", folder: "100MSDCF", stem: "DSC0001", ext: "HIF")
        // 101: empty
        try mkdir(card: "MyCard", folder: "101MSDCF")
        // 102: only ARW (no HIF) — not a complete pair per FolderStats
        try write(card: "MyCard", folder: "102MSDCF", stem: "DSC0500", ext: "ARW")

        let found = VolumeScanner.findCardFolders(volumesRoot: tmpRoot.path)
        XCTAssertEqual(found.count, 1, "only the fully-paired 100MSDCF qualifies")
        XCTAssertTrue(found[0].hasSuffix("/100MSDCF"))
    }

    func test_findCardFolders_returnsOneEntryPerRollPerCard_sorted() throws {
        // Two cards, multiple rolls each. Verify each qualifying roll is
        // returned and that the output is alphabetically sorted.
        try write(card: "CardA", folder: "101MSDCF", stem: "DSC1001", ext: "ARW")
        try write(card: "CardA", folder: "101MSDCF", stem: "DSC1001", ext: "HIF")
        try write(card: "CardA", folder: "100MSDCF", stem: "DSC1002", ext: "ARW")
        try write(card: "CardA", folder: "100MSDCF", stem: "DSC1002", ext: "HIF")
        try write(card: "CardB", folder: "100MSDCF", stem: "DSC2001", ext: "ARW")
        try write(card: "CardB", folder: "100MSDCF", stem: "DSC2001", ext: "HIF")

        let found = VolumeScanner.findCardFolders(volumesRoot: tmpRoot.path)
        XCTAssertEqual(found.count, 3)
        // Sorted lexicographically — CardA/100, CardA/101, CardB/100.
        XCTAssertTrue(found[0].hasSuffix("/CardA/DCIM/100MSDCF"))
        XCTAssertTrue(found[1].hasSuffix("/CardA/DCIM/101MSDCF"))
        XCTAssertTrue(found[2].hasSuffix("/CardB/DCIM/100MSDCF"))
    }

    func test_findCardFolders_skipsVolumesWithoutDCIM() throws {
        // A non-camera disk: no DCIM at all.
        try FileManager.default.createDirectory(
            at: tmpRoot.appendingPathComponent("RegularDisk/Stuff"),
            withIntermediateDirectories: true
        )
        // A camera-like card alongside.
        try write(card: "MyCard", folder: "100MSDCF", stem: "DSC0001", ext: "ARW")
        try write(card: "MyCard", folder: "100MSDCF", stem: "DSC0001", ext: "HIF")

        let found = VolumeScanner.findCardFolders(volumesRoot: tmpRoot.path)
        XCTAssertEqual(found.count, 1)
    }

    func test_findCardFolders_missingRoot_returnsEmpty() {
        let found = VolumeScanner.findCardFolders(volumesRoot: "/does/not/exist")
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: ViewerState.isCardShootPath (matches whichever paths get
    // skipped from RecentShoots)

    @MainActor
    func test_isCardShootPath_acceptsCanonicalCardLayout() {
        XCTAssertTrue(ViewerState.isCardShootPath(
            URL(fileURLWithPath: "/Volumes/Untitled/DCIM/100MSDCF")))
        XCTAssertTrue(ViewerState.isCardShootPath(
            URL(fileURLWithPath: "/Volumes/MyCard/DCIM/101MSDCF")))
        XCTAssertTrue(ViewerState.isCardShootPath(
            URL(fileURLWithPath: "/Volumes/SD/DCIM/100APPLE")))
    }

    @MainActor
    func test_isCardShootPath_rejectsRegularPaths() {
        XCTAssertFalse(ViewerState.isCardShootPath(
            URL(fileURLWithPath: "/Users/me/Pictures/2026-05-18")))
        XCTAssertFalse(ViewerState.isCardShootPath(
            URL(fileURLWithPath: "/Users/me/Pictures/DCIM/100MSDCF")),
            "DCIM at non-/Volumes location is NOT a card path")
        XCTAssertFalse(ViewerState.isCardShootPath(
            URL(fileURLWithPath: "/Volumes/Untitled/DCIM/MISC")),
            "MISC isn't a DCIM-convention folder")
        XCTAssertFalse(ViewerState.isCardShootPath(
            URL(fileURLWithPath: "/Volumes/Untitled/Photos/100MSDCF")),
            "second-to-last segment must be DCIM")
        XCTAssertFalse(ViewerState.isCardShootPath(
            URL(fileURLWithPath: "/Volumes/Untitled")),
            "card root isn't a shoot")
    }

    // MARK: VolumeWatcher lifecycle (idempotency)

    @MainActor
    func test_volumeWatcher_startStop_idempotent() async {
        let w = VolumeWatcher()
        w.start()
        w.start()  // no-op
        w.stop()
        w.stop()   // no-op
        // cardFolders is empty (no real /Volumes scan during tests would
        // typically find a removable card on a CI / dev machine).
        XCTAssertTrue(w.cardFolders.isEmpty)
    }
}
