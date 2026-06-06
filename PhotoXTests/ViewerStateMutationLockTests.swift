import XCTest
import IndexingCore
@testable import PhotoX

/// Verifies that user-mutating handlers on ViewerState early-return
/// while `indexingStatus` is `.loadingShoot` or `.indexing(...)` and
/// run normally when `.done` / `.idle`. Regression here = users can
/// rate / label / re-index mid-flight and race the active pipelines.
@MainActor
final class ViewerStateMutationLockTests: XCTestCase {

    private var state: ViewerState!

    override func setUp() async throws {
        try await super.setUp()
        state = ViewerState()
    }

    override func tearDown() async throws {
        state = nil
        try await super.tearDown()
    }

    // MARK: - isUserMutationLocked invariant

    func test_lock_idleIsUnlocked() {
        state.indexingStatus = .idle
        XCTAssertFalse(state.isUserMutationLocked)
    }

    func test_lock_doneIsUnlocked() {
        state.indexingStatus = .done
        XCTAssertFalse(state.isUserMutationLocked)
    }

    func test_lock_cancelledIsUnlocked() {
        state.indexingStatus = .cancelled
        XCTAssertFalse(state.isUserMutationLocked)
    }

    func test_lock_loadingShootIsLocked() {
        state.indexingStatus = .loadingShoot
        XCTAssertTrue(state.isUserMutationLocked)
    }

    func test_lock_indexingIsLocked() {
        state.indexingStatus = .indexing(percent: 0.42)
        XCTAssertTrue(state.isUserMutationLocked)
    }

    // MARK: - gated handlers

    func test_setRating_blockedWhileIndexing() {
        let entry = makeEntry("A")
        state.shoot = Shoot(folderURL: URL(fileURLWithPath: "/tmp/x"),
                            entries: [entry])
        state.currentIndex = 0
        state.entryXMPs["A"] = XMPSidecar()

        state.indexingStatus = .indexing(percent: 0.1)
        state.setRating(5)
        XCTAssertNil(state.entryXMPs["A"]?.rating,
                     "setRating must no-op while indexing is locked")

        state.indexingStatus = .done
        state.setRating(5)
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 5,
                       "setRating must apply normally once unlocked")
    }

    func test_setRatingForEntry_blockedWhileIndexing() {
        let target = makeEntry("B")
        state.shoot = Shoot(folderURL: URL(fileURLWithPath: "/tmp/x"),
                            entries: [target])
        state.entryXMPs["B"] = XMPSidecar()

        state.indexingStatus = .indexing(percent: 0.1)
        state.setRating(-1, for: target)
        XCTAssertNil(state.entryXMPs["B"]?.rating,
                     "sibling-targeted setRating must no-op when locked")
    }

    func test_setLabel_blockedWhileIndexing() {
        let entry = makeEntry("C")
        state.shoot = Shoot(folderURL: URL(fileURLWithPath: "/tmp/x"),
                            entries: [entry])
        state.currentIndex = 0
        state.entryXMPs["C"] = XMPSidecar()

        state.indexingStatus = .indexing(percent: 0.1)
        state.setLabel("Red")
        XCTAssertNil(state.entryXMPs["C"]?.label,
                     "setLabel must no-op while locked")

        state.indexingStatus = .done
        state.setLabel("Red")
        XCTAssertEqual(state.entryXMPs["C"]?.label, "Red",
                       "setLabel must apply once unlocked")
    }

    func test_reIndex_blockedWhileLoadingShoot() {
        let entry = makeEntry("D")
        state.shoot = Shoot(folderURL: URL(fileURLWithPath: "/tmp/x"),
                            entries: [entry])
        // Seed observable state that reIndex normally clears so
        // we can detect whether the no-op held.
        state.entryFingerprints = ["D": IndexFingerprint(size: 1, mtimeNanos: 1)]

        state.indexingStatus = .loadingShoot
        state.reIndex()
        XCTAssertEqual(state.indexingStatus, .loadingShoot,
                       "reIndex must leave status untouched when locked")
        XCTAssertEqual(state.entryFingerprints["D"]?.size, 1,
                       "reIndex must not clear fingerprints when locked")
    }

    // MARK: - helpers

    private func makeEntry(_ stem: String) -> PhotoEntry {
        PhotoEntry(rawURL: nil,
                   previewURL: URL(fileURLWithPath: "/tmp/x/\(stem).HIF"),
                   stem: stem)
    }
}
