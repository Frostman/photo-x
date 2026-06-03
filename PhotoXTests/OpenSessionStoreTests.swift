import XCTest
@testable import PhotoX

/// `OpenSessionStore` writes to `AppDefaults.shared` — the real
/// prod prefs file under production builds. Each test writes and
/// then immediately clears so side effects stay contained.
@MainActor
final class OpenSessionStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OpenSessionStore.clear()
    }

    override func tearDown() {
        OpenSessionStore.clear()
        super.tearDown()
    }

    func test_capture_then_restore_roundTrips() {
        let paths = ["/tmp/a", "/tmp/b", "/tmp/c"]
        OpenSessionStore.capture(paths)
        XCTAssertEqual(OpenSessionStore.restore(), paths,
                       "restore must return the captured list in order")
    }

    func test_restore_returnsEmpty_whenNothingStored() {
        XCTAssertEqual(OpenSessionStore.restore(), [])
    }

    func test_capture_empty_clearsKey() {
        OpenSessionStore.capture(["/tmp/x"])
        OpenSessionStore.capture([])
        XCTAssertEqual(OpenSessionStore.restore(), [],
                       "capture([]) must clear so the launch chain falls through")
    }

    func test_clear_emptiesPriorCapture() {
        OpenSessionStore.capture(["/tmp/x", "/tmp/y"])
        OpenSessionStore.clear()
        XCTAssertEqual(OpenSessionStore.restore(), [])
    }

    func test_capture_overwritesPriorCapture() {
        OpenSessionStore.capture(["/tmp/a", "/tmp/b"])
        OpenSessionStore.capture(["/tmp/c"])
        XCTAssertEqual(OpenSessionStore.restore(), ["/tmp/c"],
                       "later capture must replace the earlier list, not merge")
    }

    func test_restore_preservesArbitraryPathContents() {
        // Card paths, share paths, paths with spaces and Unicode —
        // session restore intentionally keeps them all; soft-fail
        // happens later at load-time via OpenShootRouter.
        let paths = [
            "/Volumes/CFExpress/DCIM/100SONY",
            "/Volumes/photos-share/Bob's shoots/2026-06-01",
            "/Users/frostman/Pictures/Hochzeit Müller",
        ]
        OpenSessionStore.capture(paths)
        XCTAssertEqual(OpenSessionStore.restore(), paths)
    }
}
