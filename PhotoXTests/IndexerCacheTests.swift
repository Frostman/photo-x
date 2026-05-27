import XCTest
@testable import PhotoX

@MainActor
final class IndexerCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IndexerCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
        // CRITICAL: redirect the indexer cache to a per-test
        // subdirectory so we don't touch the user's real
        // ~/Library/Caches/PhotoX/IndexerCache/ during tests.
        // (gcIfNeeded + deleteAllCaches operate on the root —
        // without isolation, the GC test would evict the user's
        // actual shoot caches.)
        let cacheRoot = tempDir.appendingPathComponent(".indexer-cache")
        try FileManager.default.createDirectory(at: cacheRoot,
                                                 withIntermediateDirectories: true)
        IndexerCache.setRootDirectoryForTests(cacheRoot)
        IndexerCache.policy = IndexerCache.Policy()
    }

    override func tearDownWithError() throws {
        IndexerCache.setRootDirectoryForTests(nil)
        try? FileManager.default.removeItem(at: tempDir)
        IndexerCache.policy = IndexerCache.Policy()
        try super.tearDownWithError()
    }

    // MARK: - helpers

    private func makeSourceFile(name: String, bytes: Int = 64) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    // MARK: - round-trip

    func test_roundTrip_persistsAndReloadsEntry() async throws {
        let source = try makeSourceFile(name: "DSC04207.HIF")
        let cache = IndexerCache(shootFolder: tempDir)
        XCTAssertEqual(cache.entryCount, 0, "fresh shoot starts empty")

        let exif = ExifSummary(camera: "Sony ILCE-1M2",
                               lens: "FE 50mm F1.4 GM",
                               shutterSpeed: "1/200",
                               aperture: "f/5.6",
                               iso: "ISO 400")
        let fp = try IndexerCache.fingerprint(of: source)
        cache.updateEntry(stem: "DSC04207",
                          fingerprint: fp,
                          exif: exif,
                          sequenceNumber: 3)
        await cache.flush()

        // New IndexerCache instance against the same shoot —
        // should read back what we wrote.
        let reread = IndexerCache(shootFolder: tempDir)
        let hit = reread.entry(for: "DSC04207", fingerprint: fp)
        XCTAssertNotNil(hit, "entry must reload from disk")
        XCTAssertEqual(hit?.exif?.camera, "Sony ILCE-1M2")
        XCTAssertEqual(hit?.sequenceNumber, 3)
    }

    // MARK: - fingerprint mismatch

    func test_entry_returnsNilWhenFingerprintMismatches() async throws {
        let source = try makeSourceFile(name: "DSC00001.JPG", bytes: 64)
        let cache = IndexerCache(shootFolder: tempDir)
        let originalFP = try IndexerCache.fingerprint(of: source)
        cache.updateEntry(stem: "DSC00001", fingerprint: originalFP,
                          sequenceNumber: 1)
        // Mutate the file → new fingerprint → cache lookup with
        // the new fingerprint returns nil (the cached entry is
        // still keyed by the OLD fingerprint).
        try Data(count: 128).write(to: source)
        let mutatedFP = try IndexerCache.fingerprint(of: source)
        XCTAssertNotEqual(originalFP, mutatedFP,
                          "size change should produce a different fingerprint")
        XCTAssertNil(cache.entry(for: "DSC00001", fingerprint: mutatedFP),
                     "fingerprint mismatch should invalidate the cache entry")
    }

    func test_fingerprint_throwsWhenFileMissing() async throws {
        let source = try makeSourceFile(name: "DSC00002.JPG")
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try IndexerCache.fingerprint(of: source),
                             "missing source file should throw")
    }

    // MARK: - policy gates

    func test_policy_disabledFieldsAreNotStored() async throws {
        let source = try makeSourceFile(name: "DSC00003.JPG")
        IndexerCache.policy.cacheExifSummary = false
        IndexerCache.policy.cacheSequence    = true

        let cache = IndexerCache(shootFolder: tempDir)
        let fp = try IndexerCache.fingerprint(of: source)
        cache.updateEntry(stem: "DSC00003",
                          fingerprint: fp,
                          exif: ExifSummary(camera: "Sony"),
                          sequenceNumber: 7)
        let stored = cache.entry(for: "DSC00003", fingerprint: fp)
        XCTAssertNil(stored?.exif,
                     "EXIF must NOT be stored when policy disables it")
        XCTAssertEqual(stored?.sequenceNumber, 7,
                       "SequenceNumber must still be stored")
    }

    // MARK: - version bump invalidates

    func test_versionBump_treatsOldFileAsMiss() async throws {
        let source = try makeSourceFile(name: "DSC00004.JPG")
        let cache = IndexerCache(shootFolder: tempDir)
        let fp = try IndexerCache.fingerprint(of: source)
        cache.updateEntry(stem: "DSC00004", fingerprint: fp,
                          sequenceNumber: 1)
        await cache.flush()

        // Simulate a future schema bump by hand-writing a
        // payload with a different version field directly to
        // the cache file.
        let url = IndexerCache.cacheURL(for: tempDir)
        let bumped = IndexerCache.Payload(
            version: IndexerCache.currentSchemaVersion + 1,
            shootFolderPath: tempDir.standardizedFileURL.path,
            entries: ["DSC99999": IndexerCache.Entry(
                fingerprint: IndexerCache.Fingerprint(size: 1, mtimeNanos: 0),
                sequenceNumber: 42)]
        )
        let data = try PropertyListEncoder().encode(bumped)
        try data.write(to: url, options: .atomic)

        // Fresh instance — should discard the future-version
        // file and start empty.
        let reread = IndexerCache(shootFolder: tempDir)
        XCTAssertEqual(reread.entryCount, 0,
                       "version mismatch must discard the whole file")
    }

    // MARK: - GC

    func test_gcIfNeeded_evictsOldestUntilUnderCap() async throws {
        // Three distinct "shoots" in subfolders under tempDir
        // so cacheURL hashes differently for each.
        let aDir = tempDir.appendingPathComponent("a")
        let bDir = tempDir.appendingPathComponent("b")
        let cDir = tempDir.appendingPathComponent("c")
        for dir in [aDir, bDir, cDir] {
            try FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            let src = dir.appendingPathComponent("dummy.jpg")
            try Data(count: 16).write(to: src)
        }
        for dir in [aDir, bDir, cDir] {
            let cache = IndexerCache(shootFolder: dir)
            let src = dir.appendingPathComponent("dummy.jpg")
            let fp = try IndexerCache.fingerprint(of: src)
            cache.updateEntry(stem: "dummy",
                              fingerprint: fp,
                              // Big-ish payload so each cache file is non-trivial
                              thumbnailJPEG: Data(repeating: 0xAB, count: 10_000))
            await cache.flush()
        }
        // Manually backdate mtimes by seconds so the GC's LRU
        // sort has unambiguous ordering even when all three
        // writes land within the same second. (FileManager's
        // .modificationDate setter rounds to seconds.)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-300)],
            ofItemAtPath: IndexerCache.cacheURL(for: aDir).path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-200)],
            ofItemAtPath: IndexerCache.cacheURL(for: bDir).path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-100)],
            ofItemAtPath: IndexerCache.cacheURL(for: cDir).path)
        // Set the cap below the total size — GC should drop
        // the oldest (a) but keep the two newest (b, c).
        let total = IndexerCache.totalSize()
        XCTAssertGreaterThan(total, 20_000)
        IndexerCache.policy.maxTotalBytes = total / 2

        IndexerCache.gcIfNeeded()
        let after = IndexerCache.totalSize()
        XCTAssertLessThanOrEqual(after, IndexerCache.policy.maxTotalBytes,
                                  "GC should bring total under the cap")
        // The oldest (a) should be gone.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: IndexerCache.cacheURL(for: aDir).path),
                       "oldest cache file must be evicted")
    }
}
