import XCTest
@testable import PhotoX

/// Coverage for `ViewerState.filmstripVisible(collapseActive:)` — the
/// cached derivation of the filmstrip body's per-nav computation
/// (filter + collapse + bracket precompute). Without caching this is
/// the dominant per-key-press cost on 25k mixed-burst shoots.
///
/// Tests use the test-only `filmstripVisibleComputesForTests` counter
/// (incremented inside `computeFilmstripVisible`) to assert cache-hit
/// vs cache-miss behavior. We never directly inspect the cache
/// storage — only the externally-visible compute count and the
/// returned values.
@MainActor
final class FilmstripVisibleCacheTests: XCTestCase {

    // MARK: - Cache hits (key didn't change)

    func test_identicalCalls_hitCache() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1,
                       "Second call with identical inputs must hit cache")
        // 100 more calls should not trigger any recomputes.
        for _ in 0 ..< 100 {
            _ = state.filmstripVisible(collapseActive: false)
        }
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
    }

    func test_navWithinSameBurst_hitsCache() {
        // Shoot: standalone S0, burst (B1,B2,B3,B4), standalone S5.
        // displayedIndex moves through B1, B2, B3 — all in the same burst, so
        // expandedBurstID stays constant → cache hit.
        let state = makeMixedState()
        state.displayedIndex = 1                              // B1
        _ = state.filmstripVisible(collapseActive: true)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        state.displayedIndex = 2                              // B2, same burst
        _ = state.filmstripVisible(collapseActive: true)
        state.displayedIndex = 3                              // B3, same burst
        _ = state.filmstripVisible(collapseActive: true)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1,
                       "Nav within the same multi-frame burst must hit cache")
    }

    func test_navBetweenStandalones_hitsCache() {
        // Shoot: standalone S0, burst (B1..B3), standalone S4, standalone S5.
        // Moving displayedIndex between S0/S4/S5 keeps expandedBurstID = nil
        // (singletons aren't subject to collapse), so the cache stays hot.
        let state = makeMixedState()
        state.displayedIndex = 4                              // S4
        _ = state.filmstripVisible(collapseActive: true)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        state.displayedIndex = 5                              // S5
        _ = state.filmstripVisible(collapseActive: true)
        state.displayedIndex = 0                              // S0
        _ = state.filmstripVisible(collapseActive: true)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1,
                       "Nav between standalones must hit cache")
    }

    // MARK: - Cache misses (key changed)

    func test_differentShowRejected_misses() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        state.showRejected = false
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2)
    }

    func test_differentShowUnrated_misses() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        state.showUnrated = false
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2)
    }

    func test_differentShowStars_misses() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        state.showStars.remove(5)
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2)
    }

    func test_differentCollapseActive_misses() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        _ = state.filmstripVisible(collapseActive: true)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2)
    }

    func test_navBetweenDifferentBursts_misses() {
        // Two multi-frame bursts: (A1,A2,A3) and (B1,B2,B3). Moving between
        // them changes expandedBurstID → cache miss.
        let state = makeTwoBurstState()
        state.displayedIndex = 0                              // A1
        _ = state.filmstripVisible(collapseActive: true)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        state.displayedIndex = 3                              // B1 (different burst)
        _ = state.filmstripVisible(collapseActive: true)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2,
                       "Moving between different multi-frame bursts must miss cache")
    }

    func test_differentSortMode_misses() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        state.setSortMode(.scoreDescending)
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertGreaterThanOrEqual(state.filmstripVisibleComputesForTests, 2,
                                    "Sort mode change must miss cache (setSortMode also calls invalidateSortedEntriesCache)")
    }

    // MARK: - Invalidation triggers

    func test_setRating_invalidates() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        // Rating mutation runs invalidateSortedEntriesCache → invalidateFilmstripVisibleCache.
        // The async XMP file write will fail (fake paths) but the SYNCHRONOUS
        // invalidate runs first; we assert against the immediate state.
        let target = state.shoot!.entries[0]
        state.setRating(5, for: target)
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertGreaterThanOrEqual(state.filmstripVisibleComputesForTests, 2,
                                    "setRating must invalidate the filmstrip cache")
    }

    func test_recomputeBurstIDs_invalidates() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        state.recomputeBurstIDs()
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2,
                       "recomputeBurstIDs must invalidate the filmstrip cache")
    }

    func test_flippingShowRejected_invalidatesViaDidSet() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        state.showRejected = false                            // didSet fires
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2)
    }

    func test_settingShowRejectedToSameValue_doesNotInvalidate() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        // Same-value write — didSet sees oldValue == newValue, skips invalidate.
        state.showRejected = true
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1,
                       "No-op writes to showRejected must not invalidate")
    }

    func test_modifyingShowStars_invalidatesViaDidSet() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        state.showStars.remove(5)
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2)
    }

    func test_closeShoot_invalidatesAndClears() {
        let state = makeBurstState()
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 1)
        state.closeShoot()
        // After closeShoot, the cache is cleared. Without a shoot,
        // filmstripVisible returns empty arrays — but that still requires
        // a recompute (cache was nil'd).
        _ = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(state.filmstripVisibleComputesForTests, 2,
                       "closeShoot must clear the cache")
    }

    // MARK: - Correctness

    func test_filterOutRejected_dropsRejectedFromResult() {
        let state = makeBurstState()
        state.entryXMPs = ["A": XMPSidecar(rating: -1)]       // reject A
        let withRejects = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(withRejects.allVisible.count, 3,
                       "showRejected default = true → A is visible")
        state.showRejected = false
        let withoutRejects = state.filmstripVisible(collapseActive: false)
        XCTAssertEqual(withoutRejects.allVisible.count, 2)
        XCTAssertFalse(withoutRejects.allVisible.contains { $0.element.stem == "A" })
    }

    func test_collapseActive_keepsOneRepPerBurst() {
        // Two bursts (A1,A2,A3) and (B1,B2,B3) — collapsed view shows
        // one rep per burst (A1, B1) plus the expanded burst's frames.
        let state = makeTwoBurstState()
        state.displayedIndex = 0                              // A1
        let r = state.filmstripVisible(collapseActive: true)
        // A burst is expanded (3 entries) + B burst collapsed (1 rep) = 4.
        XCTAssertEqual(r.visible.count, 4)
        let stems = r.visible.map(\.element.stem)
        XCTAssertEqual(stems, ["A1", "A2", "A3", "B1"])
    }

    func test_firstAndLastByBurst_areCorrectIndicesIntoVisible() {
        let state = makeTwoBurstState()
        let r = state.filmstripVisible(collapseActive: false)
        // No collapse → visible == all 6 entries in order.
        let aBurstID = state.burstIDByStem["A1"]!
        let bBurstID = state.burstIDByStem["B1"]!
        XCTAssertEqual(r.firstByBurst[aBurstID], 0)
        XCTAssertEqual(r.lastByBurst[aBurstID],  2)
        XCTAssertEqual(r.firstByBurst[bBurstID], 3)
        XCTAssertEqual(r.lastByBurst[bBurstID],  5)
    }

    func test_scoreMode_skipsBracketTables() {
        // useBrackets = (sortMode == .name); score modes return empty
        // firstByBurst / lastByBurst regardless of input.
        let state = makeTwoBurstState()
        state.setSortMode(.scoreDescending)
        let r = state.filmstripVisible(collapseActive: false)
        XCTAssertTrue(r.firstByBurst.isEmpty)
        XCTAssertTrue(r.lastByBurst.isEmpty)
    }

    // MARK: - helpers

    /// Three-frame burst, no standalones. Used for the simplest cache
    /// hit/miss scenarios where expandedBurstID is fixed.
    private func makeBurstState() -> ViewerState {
        makeState(stems: ["A", "B", "C"], seq: ["A": 1, "B": 2, "C": 3])
    }

    /// Mixed shoot: standalone S0, burst (B1..B3), standalone S4, S5.
    /// Indices: 0=S0, 1=B1, 2=B2, 3=B3, 4=S4, 5=S5.
    private func makeMixedState() -> ViewerState {
        makeState(
            stems: ["S0", "B1", "B2", "B3", "S4", "S5"],
            seq: ["B1": 10, "B2": 11, "B3": 12]
        )
    }

    /// Two consecutive multi-frame bursts: (A1,A2,A3) (B1,B2,B3).
    private func makeTwoBurstState() -> ViewerState {
        makeState(
            stems: ["A1", "A2", "A3", "B1", "B2", "B3"],
            seq: ["A1": 1, "A2": 2, "A3": 3, "B1": 100, "B2": 101, "B3": 102]
        )
    }

    private func makeState(stems: [String], seq: [String: Int]) -> ViewerState {
        let dir = URL(fileURLWithPath: "/tmp/photox-filmstrip-cache-tests-fake")
        let pairs = stems.map { stem in
            PhotoEntry(
                rawURL: dir.appendingPathComponent("\(stem).ARW"),
                previewURL: dir.appendingPathComponent("\(stem).HIF"),
                stem: stem
            )
        }
        let state = ViewerState()
        state.shoot = Shoot(folderURL: dir, entries: pairs)
        state.entrySequenceNumber = seq
        // recomputeBurstIDs invalidates the filmstrip cache too — call it
        // BEFORE any test code that wants to measure compute counts.
        state.recomputeBurstIDs()
        return state
    }
}
