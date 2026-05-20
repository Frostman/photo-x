import XCTest
@testable import PhotoX

/// `PendingReopenStore` writes to `AppDefaults.shared` — which
/// under the production build is the real prod prefs file. We can't
/// safely test against that here, so these tests verify the small
/// amount of behavior that doesn't require swapping the defaults
/// store: round-trip, expiry, clear. They write & immediately
/// clear so any side effect is fully contained within each test.
@MainActor
final class PendingReopenStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PendingReopenStore.clear()
    }

    override func tearDown() {
        PendingReopenStore.clear()
        super.tearDown()
    }

    func test_set_then_consume_roundTrips() {
        let url = URL(fileURLWithPath: "/tmp/photox-reopen-test")
        PendingReopenStore.set(url: url)
        let consumed = PendingReopenStore.consume()
        XCTAssertEqual(consumed?.path, url.path)
    }

    func test_consume_clears_so_secondCall_returnsNil() {
        PendingReopenStore.set(url: URL(fileURLWithPath: "/tmp/x"))
        _ = PendingReopenStore.consume()
        XCTAssertNil(PendingReopenStore.consume(),
                     "consume must be one-shot — second call should be nil")
    }

    func test_consume_returnsNil_whenNothingSet() {
        XCTAssertNil(PendingReopenStore.consume())
    }

    func test_clear_emptiesPriorSet() {
        PendingReopenStore.set(url: URL(fileURLWithPath: "/tmp/x"))
        PendingReopenStore.clear()
        XCTAssertNil(PendingReopenStore.consume())
    }

    func test_consume_returnsNil_whenStale() {
        // Plant a stale entry directly: set the path key but back-
        // date the timestamp past the 10-min window.
        AppDefaults.shared.set("/tmp/x", forKey: "pendingReopen.path")
        AppDefaults.shared.set(Date().timeIntervalSince1970 - 700,
                                forKey: "pendingReopen.timestamp")
        XCTAssertNil(PendingReopenStore.consume(),
                     "stale (>10 min) entries must be dropped")
        // And the stale keys must be cleared so they don't haunt
        // future calls.
        XCTAssertNil(AppDefaults.shared.string(forKey: "pendingReopen.path"))
    }
}
