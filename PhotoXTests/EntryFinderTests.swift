import XCTest
import IndexingCore
@testable import PhotoX

final class EntryFinderTests: XCTestCase {

    // MARK: entries(in:)

    func test_entries_ARW_plus_HIF_pair() {
        let arw = URL(fileURLWithPath: "/x/DSC04177.ARW")
        let hif = URL(fileURLWithPath: "/x/DSC04177.HIF")
        let entries = EntryFinder.entries(in: [arw, hif])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].stem, "DSC04177")
        XCTAssertEqual(entries[0].rawURL, arw)
        XCTAssertEqual(entries[0].previewURL, hif)
    }

    func test_entries_ARW_plus_JPG_pair() {
        let arw = URL(fileURLWithPath: "/x/DSC00060.ARW")
        let jpg = URL(fileURLWithPath: "/x/DSC00060.JPG")
        let entries = EntryFinder.entries(in: [arw, jpg])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].rawURL, arw)
        XCTAssertEqual(entries[0].previewURL, jpg,
                       "JPG should fill the preview slot when no HIF exists")
        XCTAssertTrue(entries[0].hasJPGPreview)
    }

    func test_entries_ARW_plus_HIF_plus_JPG_prefers_HIF() {
        let arw = URL(fileURLWithPath: "/x/A.ARW")
        let hif = URL(fileURLWithPath: "/x/A.HIF")
        let jpg = URL(fileURLWithPath: "/x/A.JPG")
        let entries = EntryFinder.entries(in: [arw, hif, jpg])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].previewURL, hif,
                       "HIF should win over JPG when both exist for the same stem")
        XCTAssertFalse(entries[0].hasJPGPreview)
    }

    func test_entries_standalone_JPG_no_ARW() {
        let jpg = URL(fileURLWithPath: "/x/IMG_0001.jpg")
        let entries = EntryFinder.entries(in: [jpg])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].rawURL)
        XCTAssertEqual(entries[0].previewURL, jpg)
        XCTAssertTrue(entries[0].hasJPGPreview)
    }

    func test_entries_standalone_HIF_no_ARW() {
        let hif = URL(fileURLWithPath: "/x/orphan.HIF")
        let entries = EntryFinder.entries(in: [hif])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].rawURL)
        XCTAssertEqual(entries[0].previewURL, hif)
        XCTAssertFalse(entries[0].hasJPGPreview)
    }

    func test_entries_ARW_only_is_dropped() {
        let arw = URL(fileURLWithPath: "/x/orphan.ARW")
        let unrelated = URL(fileURLWithPath: "/x/notes.txt")
        let entries = EntryFinder.entries(in: [arw, unrelated])
        XCTAssertTrue(entries.isEmpty,
                      "ARW without a preview is out of scope — entries should be empty")
    }

    func test_entries_accepts_HEIF_and_HEIC_extensions() {
        let arw1 = URL(fileURLWithPath: "/x/A.ARW")
        let heic = URL(fileURLWithPath: "/x/A.heic")
        let arw2 = URL(fileURLWithPath: "/x/B.arw")
        let heif = URL(fileURLWithPath: "/x/B.HEIF")
        let entries = EntryFinder.entries(in: [arw1, heic, arw2, heif])
        XCTAssertEqual(entries.map(\.stem), ["A", "B"])
        XCTAssertFalse(entries.contains(where: \.hasJPGPreview))
    }

    func test_entries_sortedAscendingByStem() {
        let urls: [URL] = [
            URL(fileURLWithPath: "/x/DSC04179.HIF"),
            URL(fileURLWithPath: "/x/DSC04177.ARW"),
            URL(fileURLWithPath: "/x/DSC04178.HIF"),
            URL(fileURLWithPath: "/x/DSC04179.ARW"),
            URL(fileURLWithPath: "/x/DSC04178.ARW"),
            URL(fileURLWithPath: "/x/DSC04177.HIF"),
        ]
        let entries = EntryFinder.entries(in: urls)
        XCTAssertEqual(entries.map(\.stem), ["DSC04177", "DSC04178", "DSC04179"])
    }

    // MARK: firstEntry(in:)

    func test_firstEntry_returnsFirstByStemOrder() {
        let urls = [
            URL(fileURLWithPath: "/x/Z.ARW"),
            URL(fileURLWithPath: "/x/A.ARW"),
            URL(fileURLWithPath: "/x/Z.HIF"),
            URL(fileURLWithPath: "/x/A.HIF"),
        ]
        XCTAssertEqual(EntryFinder.firstEntry(in: urls)?.stem, "A")
    }

    func test_firstEntry_nil_whenEmpty() {
        XCTAssertNil(EntryFinder.firstEntry(in: []))
        XCTAssertNil(EntryFinder.firstEntry(in: [URL(fileURLWithPath: "/x/lone.ARW")]),
                     "ARW with no preview shouldn't produce an entry")
    }

    // MARK: expand(_:) — real filesystem

    func test_expand_directoryListsContents_filesPassThrough() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = tmp.appendingPathComponent("A.ARW")
        let b = tmp.appendingPathComponent("B.HIF")
        let c = tmp.appendingPathComponent("notes.txt")
        for u in [a, b, c] { FileManager.default.createFile(atPath: u.path, contents: Data()) }

        // Passing the dir → contents listed
        let dirResult = EntryFinder.expand([tmp])
        XCTAssertEqual(Set(dirResult.map(\.lastPathComponent)),
                       Set([a, b, c].map(\.lastPathComponent)))

        // Passing files → pass-through
        let fileResult = EntryFinder.expand([a, b])
        XCTAssertEqual(fileResult.count, 2)
    }

    func test_expand_doesNotRecurseIntoSubdirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = sub.appendingPathComponent("nested.ARW")
        FileManager.default.createFile(atPath: nested.path, contents: Data())

        let result = EntryFinder.expand([root])
        XCTAssertFalse(result.contains(where: { $0.lastPathComponent == "nested.ARW" }),
                       "expand should be one level deep only")
    }

    // MARK: ShootScanner — real filesystem

    func test_scanner_scan_returnsSortedShoot() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for stem in ["DSC0003", "DSC0001", "DSC0002"] {
            for ext in ["ARW", "HIF"] {
                let u = tmp.appendingPathComponent("\(stem).\(ext)")
                FileManager.default.createFile(atPath: u.path, contents: Data())
            }
        }
        let shoot = ShootScanner.scan(folder: tmp)
        XCTAssertEqual(shoot.entries.map(\.stem), ["DSC0001", "DSC0002", "DSC0003"])
        XCTAssertEqual(shoot.folderURL, tmp)
    }

    func test_scanner_resolve_folderDrop_focusesFirstEntry() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for stem in ["A", "B"] {
            for ext in ["ARW", "HIF"] {
                FileManager.default.createFile(
                    atPath: tmp.appendingPathComponent("\(stem).\(ext)").path,
                    contents: Data())
            }
        }
        let result = ShootScanner.resolve(droppedURLs: [tmp])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.shoot.entries.map(\.stem), ["A", "B"])
        XCTAssertEqual(result?.focus.stem, "A")
    }

    func test_scanner_resolve_fileDrop_scansParent_focusesDroppedEntry() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Two entries in the folder; user drops only the second one.
        for stem in ["A", "B"] {
            for ext in ["ARW", "HIF"] {
                FileManager.default.createFile(
                    atPath: tmp.appendingPathComponent("\(stem).\(ext)").path,
                    contents: Data())
            }
        }
        let droppedARW = tmp.appendingPathComponent("B.ARW")
        let droppedHIF = tmp.appendingPathComponent("B.HIF")
        let result = ShootScanner.resolve(droppedURLs: [droppedARW, droppedHIF])
        XCTAssertEqual(result?.shoot.entries.map(\.stem), ["A", "B"])
        XCTAssertEqual(result?.focus.stem, "B",
                       "focus should be on the dropped entry, not the first in shoot")
    }

    func test_scanner_resolve_nothingPairable_returnsNil() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(
            atPath: tmp.appendingPathComponent("notes.txt").path, contents: Data())
        XCTAssertNil(ShootScanner.resolve(droppedURLs: [tmp]))
    }

    // MARK: helpers

    private func makeTempDir(file: StaticString = #file, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoxtests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
