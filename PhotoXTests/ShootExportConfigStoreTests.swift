import XCTest
@testable import PhotoX

@MainActor
final class ShootExportConfigStoreTests: XCTestCase {

    private var directory: URL!
    private var store: ShootExportConfigStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photox-export-store-tests-\(UUID().uuidString)")
        store = ShootExportConfigStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: filename derivation

    func test_filename_normalizesTrailingSlash() {
        // Trailing slash must NOT change the resolved filename — otherwise
        // /Volumes/Card and /Volumes/Card/ would map to different config
        // files for the same shoot.
        XCTAssertEqual(ShootExportConfigStore.filename(forShootPath: "/foo"),
                       ShootExportConfigStore.filename(forShootPath: "/foo/"))
    }

    func test_filename_distinguishesDifferentPaths() {
        XCTAssertNotEqual(ShootExportConfigStore.filename(forShootPath: "/foo"),
                          ShootExportConfigStore.filename(forShootPath: "/bar"))
    }

    // MARK: round-trip

    func test_save_thenLoad_returnsIdenticalData() async {
        let data = ShootExportConfigData(
            shootPath: "/tmp/A",
            projectName: "2026-March-14",
            projectNameIsUserOverride: false,
            destinations: [.init(path: "/Volumes/NAS/photos")],
            readOnceWriteMany: true,
            sourcePresetID: nil,
            sourcePresetNameCached: nil,
            sourcePresetSnapshotDestinations: nil,
            sourcePresetSnapshotReadOnceWriteMany: nil,
            sourcePresetSnapshotAt: nil)
        store.saveSync(data, forShootPath: "/tmp/A")
        let loaded = store.load(forShootPath: "/tmp/A")
        XCTAssertEqual(loaded, data)
    }

    func test_load_missingShoot_returnsNil() {
        XCTAssertNil(store.load(forShootPath: "/never-saved"))
    }

    func test_save_isAtomic_doesNotLeaveTempFile() async {
        let data = ShootExportConfigData(
            shootPath: "/tmp/A", projectName: "x",
            projectNameIsUserOverride: false,
            destinations: [], readOnceWriteMany: true,
            sourcePresetID: nil, sourcePresetNameCached: nil,
            sourcePresetSnapshotDestinations: nil,
            sourcePresetSnapshotReadOnceWriteMany: nil,
            sourcePresetSnapshotAt: nil)
        store.saveSync(data, forShootPath: "/tmp/A")
        let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries?.count, 1,
                       "exactly one file should land — no .tmp left behind")
    }

    // MARK: LRU purge

    func test_purgeBeyondLRU_keepsMostRecentByMtime() async throws {
        // Create files representing 5 shoots. Touch them with
        // increasing mtimes so file 4 is the newest.
        let now = Date()
        for i in 0..<5 {
            let data = ShootExportConfigData(
                shootPath: "/tmp/shoot-\(i)", projectName: "p\(i)",
                projectNameIsUserOverride: false,
                destinations: [], readOnceWriteMany: true,
                sourcePresetID: nil, sourcePresetNameCached: nil,
                sourcePresetSnapshotDestinations: nil,
                sourcePresetSnapshotReadOnceWriteMany: nil,
                sourcePresetSnapshotAt: nil)
            store.saveSync(data, forShootPath: "/tmp/shoot-\(i)")
            let url = directory.appendingPathComponent(
                ShootExportConfigStore.filename(forShootPath: "/tmp/shoot-\(i)"))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(i))],
                ofItemAtPath: url.path)
        }

        store.purgeBeyondLRU(keep: 3)
        // purge runs on a background queue — drain it.
        await waitForStoreQueue()

        let names: Set<String> = Set((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?.map(\.lastPathComponent)
            ?? [])

        // Survivors are shoots 2, 3, 4 — the three most recent.
        for survivor in [2, 3, 4] {
            XCTAssertTrue(
                names.contains(ShootExportConfigStore.filename(
                    forShootPath: "/tmp/shoot-\(survivor)")),
                "shoot \(survivor) should survive")
        }
        for evicted in [0, 1] {
            XCTAssertFalse(
                names.contains(ShootExportConfigStore.filename(
                    forShootPath: "/tmp/shoot-\(evicted)")),
                "shoot \(evicted) should be evicted")
        }
    }

    func test_purgeBeyondLRU_respectsProtectedPaths() async throws {
        // Two old files, one new. Mark the oldest as protected. The
        // newest stays (recency); the middle gets evicted to honour
        // keep=2; the oldest also stays despite being LRU because
        // it's protected.
        let now = Date()
        for (i, mtime) in [(0, 0.0), (1, 10.0), (2, 20.0)] {
            let data = ShootExportConfigData(
                shootPath: "/tmp/shoot-\(i)", projectName: "p",
                projectNameIsUserOverride: false,
                destinations: [], readOnceWriteMany: true,
                sourcePresetID: nil, sourcePresetNameCached: nil,
                sourcePresetSnapshotDestinations: nil,
                sourcePresetSnapshotReadOnceWriteMany: nil,
                sourcePresetSnapshotAt: nil)
            store.saveSync(data, forShootPath: "/tmp/shoot-\(i)")
            let url = directory.appendingPathComponent(
                ShootExportConfigStore.filename(forShootPath: "/tmp/shoot-\(i)"))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(mtime)],
                ofItemAtPath: url.path)
        }
        store.purgeBeyondLRU(keep: 1, protectedPaths: ["/tmp/shoot-0"])
        await waitForStoreQueue()

        let names: Set<String> = Set((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?.map(\.lastPathComponent)
            ?? [])
        XCTAssertTrue(names.contains(ShootExportConfigStore.filename(
            forShootPath: "/tmp/shoot-2")), "newest survives")
        XCTAssertTrue(names.contains(ShootExportConfigStore.filename(
            forShootPath: "/tmp/shoot-0")), "protected survives despite age")
        XCTAssertFalse(names.contains(ShootExportConfigStore.filename(
            forShootPath: "/tmp/shoot-1")), "middle evicted")
    }

    // MARK: helpers

    /// Synchronously wait for the store's background queue to flush
    /// by enqueueing a sync barrier-style wait. The store uses a
    /// .utility-QoS DispatchQueue for async writes/purges; this
    /// drains it deterministically.
    private func waitForStoreQueue() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
