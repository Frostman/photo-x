import XCTest
@testable import PhotoX

/// Coverage for HIFBytesCache's LRU + byte-budget semantics. The cache
/// sits in front of HEIFDecoder so culling that re-visits a frame
/// doesn't re-touch the source card — get/set/eviction correctness is
/// what protects that promise.
final class HIFBytesCacheTests: XCTestCase {

    func test_get_missingPathReturnsNil() async {
        let cache = HIFBytesCache(byteCapacity: 1024)
        let out = await cache.get("/does/not/exist")
        XCTAssertNil(out)
    }

    func test_setThenGet_returnsSameData() async {
        let cache = HIFBytesCache(byteCapacity: 1024)
        let data = Data(repeating: 0xAA, count: 100)
        await cache.set(data, for: "/foo.HIF")
        let out = await cache.get("/foo.HIF")
        XCTAssertEqual(out, data)
    }

    func test_set_overwritesPreviousValue_andAdjustsBytesUsed() async {
        let cache = HIFBytesCache(byteCapacity: 1024)
        await cache.set(Data(count: 100), for: "/foo.HIF")
        await cache.set(Data(count: 250), for: "/foo.HIF")
        let used = await cache.bytesUsed
        let count = await cache.count
        XCTAssertEqual(used, 250)
        XCTAssertEqual(count, 1)
    }

    // MARK: byte-budget eviction

    func test_evictsOldestWhenOverBudget() async {
        let cache = HIFBytesCache(byteCapacity: 250)
        await cache.set(Data(count: 100), for: "/a")  // 100
        await cache.set(Data(count: 100), for: "/b")  // 200
        await cache.set(Data(count: 100), for: "/c")  // 300 → over; /a evicted
        let used = await cache.bytesUsed
        XCTAssertEqual(used, 200, "third insert evicts oldest to fit budget")
        let a = await cache.get("/a")
        let b = await cache.get("/b")
        let c = await cache.get("/c")
        XCTAssertNil(a,    "oldest entry (/a) must be evicted")
        XCTAssertNotNil(b, "/b stays")
        XCTAssertNotNil(c, "/c stays")
    }

    func test_neverEvictsTheJustInsertedEntry() async {
        // Single entry larger than the budget — keeping it is better
        // than dropping it back to nothing.
        let cache = HIFBytesCache(byteCapacity: 100)
        await cache.set(Data(count: 500), for: "/huge")
        let out = await cache.get("/huge")
        XCTAssertNotNil(out, "single-entry over-budget cache must keep that entry")
    }

    // MARK: LRU bumping

    func test_get_bumpsEntryToMostRecent() async {
        let cache = HIFBytesCache(byteCapacity: 250)
        await cache.set(Data(count: 100), for: "/a")
        await cache.set(Data(count: 100), for: "/b")
        // Access /a — bumps it; /b is now oldest.
        _ = await cache.get("/a")
        await cache.set(Data(count: 100), for: "/c")
        // /b should be evicted (now oldest), /a should still be present.
        let a = await cache.get("/a")
        let b = await cache.get("/b")
        let c = await cache.get("/c")
        XCTAssertNotNil(a, "/a was bumped on get → survives")
        XCTAssertNil(b,    "/b became oldest after /a's bump → evicted")
        XCTAssertNotNil(c, "/c is the freshest")
    }

    func test_repeatedSet_keepsBumpingToMostRecent() async {
        let cache = HIFBytesCache(byteCapacity: 250)
        await cache.set(Data(count: 100), for: "/a")
        await cache.set(Data(count: 100), for: "/b")
        // Re-set /a (same key) — bumps it.
        await cache.set(Data(count: 100), for: "/a")
        await cache.set(Data(count: 100), for: "/c")
        let a = await cache.get("/a")
        let b = await cache.get("/b")
        let c = await cache.get("/c")
        XCTAssertNotNil(a, "/a was re-inserted → bumped to most-recent → survives")
        XCTAssertNil(b,    "/b became oldest after /a's re-insert → evicted")
        XCTAssertNotNil(c, "/c stays")
    }

    // MARK: clear + diagnostics

    func test_clear_resetsAll() async {
        let cache = HIFBytesCache(byteCapacity: 1024)
        await cache.set(Data(count: 100), for: "/a")
        await cache.set(Data(count: 200), for: "/b")
        await cache.clear()
        let used = await cache.bytesUsed
        let count = await cache.count
        let a = await cache.get("/a")
        XCTAssertEqual(used, 0)
        XCTAssertEqual(count, 0)
        XCTAssertNil(a)
    }

    func test_contains_reportsPresence() async {
        let cache = HIFBytesCache(byteCapacity: 1024)
        await cache.set(Data(count: 50), for: "/x")
        let hasX = await cache.contains("/x")
        let hasY = await cache.contains("/y")
        XCTAssertTrue(hasX)
        XCTAssertFalse(hasY)
    }
}
