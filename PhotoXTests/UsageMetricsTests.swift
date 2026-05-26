import XCTest
@testable import PhotoX

/// Coverage for the two-tier counter store. Each test uses an
/// isolated in-memory UserDefaults suite (volatile/random name)
/// so it never reads or writes the user's real prefs and tests
/// can run in any order. `startBackgroundLoop: false` keeps the
/// long-running persist task from racing with the assertions.
@MainActor
final class UsageMetricsTests: XCTestCase {

    private func makeStore(name: String = UUID().uuidString) -> UserDefaults {
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    // MARK: - record mutators

    func test_recordAppOpen_incrementsPendingOnly_noIO() {
        let store = makeStore()
        let metrics = UsageMetrics(store: store, startBackgroundLoop: false)

        metrics.recordAppOpen()
        XCTAssertEqual(metrics.pending.appOpens, 1)
        XCTAssertEqual(metrics.persisted.appOpens, 0)
        XCTAssertEqual(metrics.total.appOpens, 1)
        // Critical: no disk write yet.
        XCTAssertNil(store.data(forKey: UsageMetrics.Key.counters))
    }

    func test_eachRecorder_updatesCorrespondingCounter() {
        let store = makeStore()
        let metrics = UsageMetrics(store: store, startBackgroundLoop: false)

        metrics.recordPhotoSeen()
        metrics.recordPhotoSeen()
        metrics.recordShootOpened()
        metrics.recordScoreSet()
        metrics.recordExportCompleted(imageCount: 7)

        XCTAssertEqual(metrics.pending.photosSeen,       2)
        XCTAssertEqual(metrics.pending.shootsOpened,     1)
        XCTAssertEqual(metrics.pending.scoresSet,        1)
        XCTAssertEqual(metrics.pending.exportsCompleted, 1)
        XCTAssertEqual(metrics.pending.imagesExported,   7)
    }

    func test_recordExportCompleted_updatesBothCountersAtomically() {
        let store = makeStore()
        let metrics = UsageMetrics(store: store, startBackgroundLoop: false)
        metrics.recordExportCompleted(imageCount: 0)   // 0-image run is still 1 export
        metrics.recordExportCompleted(imageCount: 12)

        XCTAssertEqual(metrics.pending.exportsCompleted, 2)
        XCTAssertEqual(metrics.pending.imagesExported,   12)
    }

    // MARK: - flushPending

    func test_flushPending_drainsPendingIntoPersistedAndDisk() async {
        let store = makeStore()
        let metrics = UsageMetrics(store: store, startBackgroundLoop: false)
        metrics.recordPhotoSeen()
        metrics.recordPhotoSeen()
        metrics.recordPhotoSeen()

        await metrics.flushPending()

        XCTAssertEqual(metrics.pending, .zero)
        XCTAssertEqual(metrics.persisted.photosSeen, 3)
        XCTAssertEqual(metrics.total.photosSeen, 3)

        // Verify a round-trip: rebuild from the same suite sees
        // the persisted value.
        let metrics2 = UsageMetrics(store: store, startBackgroundLoop: false)
        XCTAssertEqual(metrics2.persisted.photosSeen, 3)
    }

    func test_flushPending_emptyIsNoop() async {
        let store = makeStore()
        let metrics = UsageMetrics(store: store, startBackgroundLoop: false)
        await metrics.flushPending()
        XCTAssertNil(store.data(forKey: UsageMetrics.Key.counters))
    }

    // MARK: - RMW under concurrent writers

    /// Simulates a second PhotoX window (or process) writing to the
    /// same UserDefaults suite between our process's flushes. The
    /// expected behaviour: on our next flushPending, we ADD our
    /// in-memory delta to whatever's currently on disk, rather than
    /// blindly overwriting with our own absolute total.
    func test_flushPending_isReadModifyWrite_preservesExternalWrites() async {
        let store = makeStore()
        let metrics = UsageMetrics(store: store, startBackgroundLoop: false)
        metrics.recordPhotoSeen()
        metrics.recordPhotoSeen()
        await metrics.flushPending()
        XCTAssertEqual(metrics.persisted.photosSeen, 2)

        // External writer (other window / process) adds 100 to the
        // blob via its own UsageMetrics instance pointing at the
        // same suite. Use a second instance + flush so we exercise
        // the real save path.
        let other = UsageMetrics(store: store, startBackgroundLoop: false)
        for _ in 0 ..< 100 { other.recordPhotoSeen() }
        await other.flushPending()

        // Now our instance accumulates more (50) and flushes. The
        // on-disk total should be 2 (us) + 100 (them) + 50 (us) = 152.
        for _ in 0 ..< 50 { metrics.recordPhotoSeen() }
        await metrics.flushPending()

        let reread = UsageMetrics(store: store, startBackgroundLoop: false)
        XCTAssertEqual(reread.persisted.photosSeen, 152,
                       "RMW should preserve the external 100, not overwrite to 52")
    }

    // MARK: - reset

    func test_reset_zeroesCounters_butPreservesTelemetryUUIDKey() async {
        let store = makeStore()
        // Simulate a previously-set telemetry UUID (the key under
        // settings.* that UsageMetrics must NOT touch).
        let uuidKey = "settings.telemetryAnonymousID"
        let uuid = UUID().uuidString
        store.set(uuid, forKey: uuidKey)

        let metrics = UsageMetrics(store: store, startBackgroundLoop: false)
        metrics.recordPhotoSeen()
        metrics.recordScoreSet()
        await metrics.flushPending()
        XCTAssertEqual(metrics.persisted.photosSeen, 1)

        await metrics.reset()

        XCTAssertEqual(metrics.persisted, .zero)
        XCTAssertEqual(metrics.pending, .zero)
        // Round-trip: counters blob is zero on disk too.
        let reread = UsageMetrics(store: store, startBackgroundLoop: false)
        XCTAssertEqual(reread.persisted, .zero)
        // Critical: UUID survived.
        XCTAssertEqual(store.string(forKey: uuidKey), uuid)
    }

    // MARK: - firstLaunchAt

    func test_firstLaunchAt_setOnceAndPersisted() {
        let store = makeStore()
        let m1 = UsageMetrics(store: store, startBackgroundLoop: false)
        let stamp = m1.firstLaunchAt

        // Rebuild — should reuse the stored value, not generate a new one.
        let m2 = UsageMetrics(store: store, startBackgroundLoop: false)
        XCTAssertEqual(m1.firstLaunchAt, stamp)
        XCTAssertEqual(m2.firstLaunchAt, stamp)
    }
}
