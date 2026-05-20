import XCTest
@testable import PhotoX

@MainActor
final class RecentShootsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "photox-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_add_insertsAtFront() {
        let r = RecentShoots(defaults: defaults)
        r.add("/a")
        r.add("/b")
        r.add("/c")
        XCTAssertEqual(r.paths, ["/c", "/b", "/a"])
    }

    func test_add_movesExistingToFront_dedupes() {
        let r = RecentShoots(defaults: defaults)
        r.add("/a"); r.add("/b"); r.add("/c"); r.add("/a")
        XCTAssertEqual(r.paths, ["/a", "/c", "/b"],
                       "Re-adding /a should move it to front, not duplicate it")
    }

    func test_add_capsAt10() {
        let r = RecentShoots(defaults: defaults)
        for i in 1...15 { r.add("/p\(i)") }
        XCTAssertEqual(r.paths.count, 10)
        XCTAssertEqual(r.paths.first, "/p15")
        XCTAssertEqual(r.paths.last,  "/p6")
    }

    func test_paths_persistAcrossInstances() {
        let r1 = RecentShoots(defaults: defaults)
        r1.add("/a"); r1.add("/b")
        let r2 = RecentShoots(defaults: defaults)
        XCTAssertEqual(r2.paths, ["/b", "/a"])
    }

    func test_clear_emptiesListAndDefaults() {
        let r = RecentShoots(defaults: defaults)
        r.add("/a"); r.add("/b")
        r.clear()
        XCTAssertTrue(r.paths.isEmpty)

        // A fresh instance using the same defaults should also see empty.
        let r2 = RecentShoots(defaults: defaults)
        XCTAssertTrue(r2.paths.isEmpty)
    }

    // MARK: lastEntry persistence

    func test_setLastEntry_roundTripsAcrossInstances() {
        let r1 = RecentShoots(defaults: defaults)
        r1.add("/shoot")
        r1.setLastEntry("DSC04207", for: "/shoot")
        XCTAssertEqual(r1.lastEntry(for: "/shoot"), "DSC04207")
        let r2 = RecentShoots(defaults: defaults)
        XCTAssertEqual(r2.lastEntry(for: "/shoot"), "DSC04207",
                       "lastEntry must survive a re-load from the same defaults")
    }

    func test_setLastEntry_isNoOpForUnknownPath() {
        let r = RecentShoots(defaults: defaults)
        r.setLastEntry("X", for: "/never-added")
        XCTAssertNil(r.lastEntry(for: "/never-added"),
                     "Don't resurrect paths the user never opened (or removed)")
    }

    func test_remove_alsoDropsLastEntry() {
        let r = RecentShoots(defaults: defaults)
        r.add("/a")
        r.setLastEntry("STEM", for: "/a")
        r.remove("/a")
        XCTAssertNil(r.lastEntry(for: "/a"))
    }

    func test_add_prunesLastEntryForPathsThatFellOffCap() {
        let r = RecentShoots(defaults: defaults)
        r.add("/p1")
        r.setLastEntry("STEM1", for: "/p1")
        // Fill past the cap so /p1 falls off the MRU.
        for i in 2 ... 12 { r.add("/p\(i)") }
        XCTAssertFalse(r.paths.contains("/p1"),
                       "precondition: /p1 fell off the 10-cap MRU")
        XCTAssertNil(r.lastEntry(for: "/p1"),
                     "lastEntry must be pruned alongside the path")
    }

    func test_clear_alsoWipesLastEntryMap() {
        let r = RecentShoots(defaults: defaults)
        r.add("/a")
        r.setLastEntry("S", for: "/a")
        r.clear()
        XCTAssertNil(r.lastEntry(for: "/a"))
        let r2 = RecentShoots(defaults: defaults)
        XCTAssertNil(r2.lastEntry(for: "/a"))
    }
}
