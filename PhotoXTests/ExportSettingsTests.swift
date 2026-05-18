import XCTest
@testable import PhotoX

@MainActor
final class ExportSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "photox-export-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: defaults / init

    func test_init_emptyDefaults_yieldsEmptyState() {
        let s = ExportSettings(defaults: defaults)
        XCTAssertEqual(s.projectName, "")
        XCTAssertTrue(s.destinations.isEmpty)
        XCTAssertFalse(s.readOnceWriteMany)
        XCTAssertFalse(s.isValidForExport)
    }

    func test_destinationDefaults_areReasonable() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/tmp/a")
        let d = s.destinations[0]
        XCTAssertEqual(d.showStars, [1, 2, 3, 4, 5])
        XCTAssertTrue(d.showRejected)
        XCTAssertTrue(d.showUnrated)
        XCTAssertTrue(d.includeARW)
        XCTAssertTrue(d.includeHIF)
        XCTAssertTrue(d.includeXMP)
        XCTAssertEqual(d.overwrite, .skipUnchangedElseOverwrite)
        XCTAssertFalse(d.removeOrphans)
    }

    // MARK: project name

    func test_projectName_setAndPersist() {
        let s = ExportSettings(defaults: defaults)
        s.setProjectName("Wedding")
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.projectName, "Wedding")
        XCTAssertTrue(s2.isValidForExport)
    }

    func test_projectName_emptyVariants_areInvalidForExport() {
        let s = ExportSettings(defaults: defaults)
        for raw in ["", "   ", "\n", "\t\t  \n"] {
            s.setProjectName(raw)
            XCTAssertFalse(s.isValidForExport, "should reject \(raw.debugDescription)")
        }
        s.setProjectName(" Trailing  ")  // whitespace around content is still valid
        XCTAssertTrue(s.isValidForExport)
    }

    // MARK: destinations CRUD

    func test_add_appendsAtEnd_setsFreshUUID() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a")
        s.add(path: "/b")
        s.add(path: "/c")
        XCTAssertEqual(s.destinations.map(\.path), ["/a", "/b", "/c"])
        let ids = Set(s.destinations.map(\.id))
        XCTAssertEqual(ids.count, 3, "every Destination should have a fresh UUID")
    }

    func test_remove_byID_persists() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a"); s.add(path: "/b"); s.add(path: "/c")
        let middleID = s.destinations[1].id
        s.remove(id: middleID)
        XCTAssertEqual(s.destinations.map(\.path), ["/a", "/c"])
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.destinations.map(\.path), ["/a", "/c"])
    }

    func test_update_byID_mutateCallback_persists() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a")
        let id = s.destinations[0].id
        s.update(id: id) { dest in
            dest.showStars = [4, 5]
            dest.includeXMP = false
            dest.overwrite = .alwaysOverwrite
            dest.removeOrphans = true
        }
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.destinations[0].showStars, [4, 5])
        XCTAssertFalse(s2.destinations[0].includeXMP)
        XCTAssertEqual(s2.destinations[0].overwrite, .alwaysOverwrite)
        XCTAssertTrue(s2.destinations[0].removeOrphans)
    }

    func test_update_missingID_isNoOp() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a")
        s.update(id: UUID()) { $0.path = "MUTATED" }
        XCTAssertEqual(s.destinations[0].path, "/a")
    }

    // MARK: move

    func test_move_before_reorders_andPersists() {
        let s = ExportSettings(defaults: defaults)
        for c in ["a", "b", "c", "d"] { s.add(path: "/\(c)") }
        let aID = s.destinations[0].id
        let dID = s.destinations[3].id
        s.move(aID, before: dID)  // a → just before d → b, c, a, d
        XCTAssertEqual(s.destinations.map(\.path), ["/b", "/c", "/a", "/d"])

        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.destinations.map(\.path), ["/b", "/c", "/a", "/d"])

        // Move dest backwards (from index > to index): d before b
        let dID2 = s2.destinations.first(where: { $0.path == "/d" })!.id
        let bID2 = s2.destinations.first(where: { $0.path == "/b" })!.id
        s2.move(dID2, before: bID2)
        XCTAssertEqual(s2.destinations.map(\.path), ["/d", "/b", "/c", "/a"])
    }

    func test_move_sameID_isNoOp() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a"); s.add(path: "/b")
        let aID = s.destinations[0].id
        s.move(aID, before: aID)
        XCTAssertEqual(s.destinations.map(\.path), ["/a", "/b"])
    }

    func test_move_missingID_isNoOp() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a")
        s.move(UUID(), before: UUID())
        XCTAssertEqual(s.destinations.map(\.path), ["/a"])
    }

    // MARK: readOnceWriteMany

    func test_readOnceWriteMany_persists() {
        let s = ExportSettings(defaults: defaults)
        s.readOnceWriteMany = true
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertTrue(s2.readOnceWriteMany)
    }

    // MARK: JSON round-trip

    func test_destinations_roundTripJSON_preservesAllFields() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/x")
        let id = s.destinations[0].id
        s.update(id: id) { d in
            d.showStars = [3]
            d.showRejected = false
            d.showUnrated = false
            d.includeARW = false
            d.includeHIF = true
            d.includeXMP = true
            d.overwrite = .skipUnchangedElseNewerOnly
            d.removeOrphans = true
        }
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.destinations.first, s.destinations.first,
                       "Codable round-trip should be loss-free")
    }
}
