import XCTest
@testable import PhotoX

final class PairFinderTests: XCTestCase {

    // MARK: pairs(in:)

    func test_pairs_simple_ARW_HIF_pair() {
        let arw  = URL(fileURLWithPath: "/x/DSC04177.ARW")
        let hif  = URL(fileURLWithPath: "/x/DSC04177.HIF")
        let pairs = PairFinder.pairs(in: [arw, hif])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].stem, "DSC04177")
        XCTAssertEqual(pairs[0].rawURL, arw)
        XCTAssertEqual(pairs[0].heifURL, hif)
    }

    func test_pairs_accepts_HEIF_and_HEIC_extensions() {
        let arw1 = URL(fileURLWithPath: "/x/A.ARW")
        let heic = URL(fileURLWithPath: "/x/A.heic")
        let arw2 = URL(fileURLWithPath: "/x/B.arw")
        let heif = URL(fileURLWithPath: "/x/B.HEIF")
        let pairs = PairFinder.pairs(in: [arw1, heic, arw2, heif])
        XCTAssertEqual(pairs.map(\.stem), ["A", "B"])
    }

    func test_pairs_drops_unpaired_orphans() {
        let arw  = URL(fileURLWithPath: "/x/DSC04177.ARW")
        let orphan = URL(fileURLWithPath: "/x/DSC04200.HIF")
        let unrelated = URL(fileURLWithPath: "/x/notes.txt")
        let pairs = PairFinder.pairs(in: [arw, orphan, unrelated])
        XCTAssertTrue(pairs.isEmpty,
                      "Only files with both ARW and HIF members should pair")
    }

    func test_pairs_sortedAscendingByStem() {
        let urls: [URL] = [
            URL(fileURLWithPath: "/x/DSC04179.HIF"),
            URL(fileURLWithPath: "/x/DSC04177.ARW"),
            URL(fileURLWithPath: "/x/DSC04178.HIF"),
            URL(fileURLWithPath: "/x/DSC04179.ARW"),
            URL(fileURLWithPath: "/x/DSC04178.ARW"),
            URL(fileURLWithPath: "/x/DSC04177.HIF"),
        ]
        let pairs = PairFinder.pairs(in: urls)
        XCTAssertEqual(pairs.map(\.stem), ["DSC04177", "DSC04178", "DSC04179"])
    }

    // MARK: firstPair(in:)

    func test_firstPair_returnsFirstByStemOrder() {
        let urls = [
            URL(fileURLWithPath: "/x/Z.ARW"),
            URL(fileURLWithPath: "/x/A.ARW"),
            URL(fileURLWithPath: "/x/Z.HIF"),
            URL(fileURLWithPath: "/x/A.HIF"),
        ]
        XCTAssertEqual(PairFinder.firstPair(in: urls)?.stem, "A")
    }

    func test_firstPair_nil_whenEmpty() {
        XCTAssertNil(PairFinder.firstPair(in: []))
        XCTAssertNil(PairFinder.firstPair(in: [URL(fileURLWithPath: "/x/lone.ARW")]))
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
        let dirResult = PairFinder.expand([tmp])
        XCTAssertEqual(Set(dirResult.map(\.lastPathComponent)),
                       Set([a, b, c].map(\.lastPathComponent)))

        // Passing files → pass-through
        let fileResult = PairFinder.expand([a, b])
        XCTAssertEqual(fileResult.count, 2)
    }

    func test_expand_doesNotRecurseIntoSubdirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = sub.appendingPathComponent("nested.ARW")
        FileManager.default.createFile(atPath: nested.path, contents: Data())

        let result = PairFinder.expand([root])
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
        XCTAssertEqual(shoot.pairs.map(\.stem), ["DSC0001", "DSC0002", "DSC0003"])
        XCTAssertEqual(shoot.folderURL, tmp)
    }

    func test_scanner_resolve_folderDrop_focusesFirstPair() throws {
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
        XCTAssertEqual(result?.shoot.pairs.map(\.stem), ["A", "B"])
        XCTAssertEqual(result?.focus.stem, "A")
    }

    func test_scanner_resolve_fileDrop_scansParent_focusesDroppedPair() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Two pairs in the folder; user drops only the second one.
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
        XCTAssertEqual(result?.shoot.pairs.map(\.stem), ["A", "B"])
        XCTAssertEqual(result?.focus.stem, "B",
                       "focus should be on the dropped pair, not the first in shoot")
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
