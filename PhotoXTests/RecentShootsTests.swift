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
}
