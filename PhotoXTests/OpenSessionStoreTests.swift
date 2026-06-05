import XCTest
@testable import PhotoX

/// `OpenSessionStore` writes to `AppDefaults.shared` — the real
/// prod prefs file under production builds. Each test writes and
/// then immediately clears so side effects stay contained.
///
/// `restore()` filters out paths that don't exist on disk (see
/// commit e6c8fe3 — stale entries shouldn't trap subsequent
/// launches into a dead-path session restore). So every test that
/// expects restore() to return a non-empty list creates the
/// referenced paths under a per-test scratch dir in setUp.
@MainActor
final class OpenSessionStoreTests: XCTestCase {

    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        OpenSessionStore.clear()
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "OpenSessionStoreTests-\(UUID().uuidString)",
                isDirectory: true)
        try! FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        OpenSessionStore.clear()
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    /// Create a file (or directory) inside `scratchDir` and return its
    /// absolute path. Lets tests reference paths with spaces, Unicode,
    /// or nested layouts without worrying about FS quoting.
    private func makePath(_ name: String, isDirectory: Bool = false) -> String {
        let url = scratchDir.appendingPathComponent(name, isDirectory: isDirectory)
        if isDirectory {
            try! FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        } else {
            try! FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url.path
    }

    func test_capture_then_restore_roundTrips() {
        let paths = [makePath("a"), makePath("b"), makePath("c")]
        OpenSessionStore.capture(paths)
        XCTAssertEqual(OpenSessionStore.restore(), paths,
                       "restore must return the captured list in order")
    }

    func test_restore_returnsEmpty_whenNothingStored() {
        XCTAssertEqual(OpenSessionStore.restore(), [])
    }

    func test_capture_empty_clearsKey() {
        OpenSessionStore.capture([makePath("x")])
        OpenSessionStore.capture([])
        XCTAssertEqual(OpenSessionStore.restore(), [],
                       "capture([]) must clear so the launch chain falls through")
    }

    func test_clear_emptiesPriorCapture() {
        OpenSessionStore.capture([makePath("x"), makePath("y")])
        OpenSessionStore.clear()
        XCTAssertEqual(OpenSessionStore.restore(), [])
    }

    func test_capture_overwritesPriorCapture() {
        let first = [makePath("a"), makePath("b")]
        let second = [makePath("c")]
        OpenSessionStore.capture(first)
        OpenSessionStore.capture(second)
        XCTAssertEqual(OpenSessionStore.restore(), second,
                       "later capture must replace the earlier list, not merge")
    }

    func test_restore_preservesArbitraryPathContents() {
        // Card-style nested dirs, share-style spaces + apostrophe,
        // Unicode — session restore intentionally keeps them all;
        // soft-fail happens later at load-time via OpenShootRouter.
        // Materialised under scratchDir so the on-disk existence
        // filter in restore() doesn't strip them.
        let paths = [
            makePath("CFExpress/DCIM/100SONY", isDirectory: true),
            makePath("photos-share/Bob's shoots/2026-06-01", isDirectory: true),
            makePath("Hochzeit Müller", isDirectory: true),
        ]
        OpenSessionStore.capture(paths)
        XCTAssertEqual(OpenSessionStore.restore(), paths)
    }
}
