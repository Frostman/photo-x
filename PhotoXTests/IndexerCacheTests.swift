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
        IndexerCache.policy = IndexerCache.Policy()
    }

    override func tearDownWithError() throws {
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
        cache.updateEntry(stem: "DSC04207",
                          sourceURL: source,
                          exif: exif,
                          sequenceNumber: 3)
        await cache.flush()

        // New IndexerCache instance against the same shoot —
        // should read back what we wrote.
        let reread = IndexerCache(shootFolder: tempDir)
        let hit = reread.entry(for: "DSC04207", sourceURL: source)
        XCTAssertNotNil(hit, "entry must reload from disk")
        XCTAssertEqual(hit?.exif?.camera, "Sony ILCE-1M2")
        XCTAssertEqual(hit?.sequenceNumber, 3)
    }

    // MARK: - fingerprint mismatch

    func test_entry_returnsNilWhenFileSizeChanges() async throws {
        let source = try makeSourceFile(name: "DSC00001.JPG", bytes: 64)
        let cache = IndexerCache(shootFolder: tempDir)
        cache.updateEntry(stem: "DSC00001", sourceURL: source,
                          sequenceNumber: 1)
        // Mutate the file: same path, different size → cache
        // must invalidate.
        try Data(count: 128).write(to: source)
        XCTAssertNil(cache.entry(for: "DSC00001", sourceURL: source),
                     "size change should invalidate cache entry")
    }

    func test_entry_returnsNilWhenFileMissing() async throws {
        let source = try makeSourceFile(name: "DSC00002.JPG")
        let cache = IndexerCache(shootFolder: tempDir)
        cache.updateEntry(stem: "DSC00002", sourceURL: source,
                          sequenceNumber: 1)
        try FileManager.default.removeItem(at: source)
        XCTAssertNil(cache.entry(for: "DSC00002", sourceURL: source),
                     "missing source file should invalidate cache entry")
    }

    // MARK: - policy gates

    func test_policy_disabledFieldsAreNotStored() async throws {
        let source = try makeSourceFile(name: "DSC00003.JPG")
        IndexerCache.policy.cacheExifSummary = false
        IndexerCache.policy.cacheSequence    = true

        let cache = IndexerCache(shootFolder: tempDir)
        cache.updateEntry(stem: "DSC00003",
                          sourceURL: source,
                          exif: ExifSummary(camera: "Sony"),
                          sequenceNumber: 7)
        let stored = cache.entry(for: "DSC00003", sourceURL: source)
        XCTAssertNil(stored?.exif,
                     "EXIF must NOT be stored when policy disables it")
        XCTAssertEqual(stored?.sequenceNumber, 7,
                       "SequenceNumber must still be stored")
    }

    // MARK: - version bump invalidates

    func test_versionBump_treatsOldFileAsMiss() async throws {
        let source = try makeSourceFile(name: "DSC00004.JPG")
        let cache = IndexerCache(shootFolder: tempDir)
        cache.updateEntry(stem: "DSC00004", sourceURL: source,
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
            cache.updateEntry(stem: "dummy",
                              sourceURL: dir.appendingPathComponent("dummy.jpg"),
                              // Big-ish payload so each cache file is non-trivial
                              thumbnailJPEG: Data(repeating: 0xAB, count: 10_000))
            await cache.flush()
        }
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
