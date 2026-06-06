import XCTest
import IndexingCore
@testable import PhotoX

/// Pins down how `IndexingWorkPlan.make(...)` buckets entries based
/// on cache + sidecar coverage. Regression here would mean the
/// indexer either re-does work the cache already has or skips work
/// it should run.
@MainActor
final class IndexingWorkPlanTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkPlan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let cacheRoot = tempDir.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        IndexerCache.setRootDirectoryForTests(cacheRoot)
    }

    override func tearDownWithError() throws {
        IndexerCache.setRootDirectoryForTests(nil)
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func entry(_ stem: String) -> PhotoEntry {
        PhotoEntry(rawURL: nil,
                   previewURL: tempDir.appendingPathComponent("\(stem).HIF"),
                   stem: stem)
    }

    private func makeShoot(entries: [PhotoEntry],
                           fingerprints: [String: IndexFingerprint] = [:],
                           xmpStems: Set<String> = []) -> Shoot {
        Shoot(folderURL: tempDir,
              entries: entries,
              previewFingerprints: fingerprints,
              xmpStems: xmpStems)
    }

    private func makeCache() -> IndexerCache {
        IndexerCache(shootFolder: tempDir)
    }

    private func fp(_ size: Int64) -> IndexFingerprint {
        IndexFingerprint(size: size, mtimeNanos: 1_700_000_000_000_000_000)
    }

    // MARK: - empty shoot

    func test_emptyShoot_producesEmptyPlan() {
        let plan = IndexingWorkPlan.make(
            shoot: makeShoot(entries: []),
            fingerprints: [:],
            cache: makeCache(),
            xmpStems: [])
        XCTAssertTrue(plan.cachedThumbBytes.isEmpty)
        XCTAssertTrue(plan.needsBasicFetch.isEmpty)
        XCTAssertTrue(plan.needsAdvancedExif.isEmpty)
        XCTAssertTrue(plan.needsXMP.isEmpty)
        XCTAssertTrue(plan.prepopulatedExif.isEmpty)
        XCTAssertTrue(plan.prepopulatedAFData.isEmpty)
        XCTAssertTrue(plan.prepopulatedSequenceNumber.isEmpty)
    }

    // MARK: - uncached shoot

    func test_uncachedShoot_everythingMisses() {
        let entries = [entry("A"), entry("B"), entry("C")]
        let prints = [
            "A": fp(1024),
            "B": fp(2048),
            "C": fp(3072),
        ]
        let plan = IndexingWorkPlan.make(
            shoot: makeShoot(entries: entries, previewFingerprints: prints),
            fingerprints: prints,
            cache: makeCache(),
            xmpStems: [])

        XCTAssertTrue(plan.cachedThumbBytes.isEmpty)
        XCTAssertEqual(plan.needsBasicFetch.map(\.stem), ["A", "B", "C"])
        XCTAssertEqual(plan.needsAdvancedExif.map(\.stem), ["A", "B", "C"])
        XCTAssertTrue(plan.needsXMP.isEmpty)
    }

    // MARK: - fully cached shoot

    func test_fullyCachedShoot_everythingPrepopulated_noFetchNeeded() {
        let entries = [entry("A"), entry("B")]
        let prints = ["A": fp(1024), "B": fp(2048)]
        let cache = makeCache()
        for entry in entries {
            cache.updateEntry(
                stem: entry.stem,
                fingerprint: prints[entry.stem]!,
                exif: ExifSummary(camera: "Sony α1 II"),
                afData: ExifToolRunner.AFData(),
                sequenceNumber: 1,
                thumbnailJPEG: Data([0xFF, 0xD8]),
                thumbnailOrientation: 1
            )
        }

        let plan = IndexingWorkPlan.make(
            shoot: makeShoot(entries: entries, previewFingerprints: prints),
            fingerprints: prints,
            cache: cache,
            xmpStems: [])

        XCTAssertEqual(plan.cachedThumbBytes.map(\.entry.stem).sorted(), ["A", "B"])
        XCTAssertTrue(plan.needsBasicFetch.isEmpty,
                      "fully cached shoot: nothing to source-read")
        XCTAssertTrue(plan.needsAdvancedExif.isEmpty,
                      "fully cached shoot: no exiftool batches")
        XCTAssertEqual(plan.prepopulatedExif.count, 2)
        XCTAssertEqual(plan.prepopulatedAFData.count, 2)
        XCTAssertEqual(plan.prepopulatedSequenceNumber.count, 2)
    }

    // MARK: - thumb-bytes-only cache

    func test_cachedThumbBytesOnly_noBasicFetch_butStillNeedsAdvanced() {
        // Cache covers thumbnail bytes + exif, but not afData/seq.
        let entries = [entry("A")]
        let prints = ["A": fp(1024)]
        let cache = makeCache()
        cache.updateEntry(stem: "A",
                          fingerprint: prints["A"]!,
                          exif: ExifSummary(camera: "Sony α1 II"),
                          thumbnailJPEG: Data([0xFF, 0xD8]),
                          thumbnailOrientation: 6)

        let plan = IndexingWorkPlan.make(
            shoot: makeShoot(entries: entries, previewFingerprints: prints),
            fingerprints: prints,
            cache: cache,
            xmpStems: [])

        XCTAssertEqual(plan.cachedThumbBytes.count, 1)
        XCTAssertEqual(plan.cachedThumbBytes.first?.orientation, 6,
                       "orientation rides along with cached bytes")
        XCTAssertTrue(plan.needsBasicFetch.isEmpty)
        XCTAssertEqual(plan.needsAdvancedExif.map(\.stem), ["A"],
                       "missing AF + seq → exiftool still needed")
        XCTAssertEqual(plan.prepopulatedExif["A"]?.camera, "Sony α1 II")
    }

    // MARK: - advanced cached, basic missing

    func test_advancedCachedButBasicMissing_basicFetchOnly() {
        // Cache covers afData/seq, but no thumb / exif.
        let entries = [entry("A")]
        let prints = ["A": fp(1024)]
        let cache = makeCache()
        cache.updateEntry(stem: "A",
                          fingerprint: prints["A"]!,
                          afData: ExifToolRunner.AFData(),
                          sequenceNumber: 5)

        let plan = IndexingWorkPlan.make(
            shoot: makeShoot(entries: entries, previewFingerprints: prints),
            fingerprints: prints,
            cache: cache,
            xmpStems: [])

        XCTAssertEqual(plan.needsBasicFetch.map(\.stem), ["A"],
                       "missing thumb + exif → source read needed")
        XCTAssertTrue(plan.needsAdvancedExif.isEmpty,
                      "afData / seq already cached")
        XCTAssertEqual(plan.prepopulatedSequenceNumber["A"], 5)
    }

    // MARK: - xmpStems gate

    func test_xmpStems_projectsOntoEntries() {
        let entries = [entry("A"), entry("B"), entry("C")]
        let prints = ["A": fp(1), "B": fp(1), "C": fp(1)]
        let plan = IndexingWorkPlan.make(
            shoot: makeShoot(entries: entries,
                             previewFingerprints: prints,
                             xmpStems: ["A", "C"]),
            fingerprints: prints,
            cache: makeCache(),
            xmpStems: ["A", "C"])
        XCTAssertEqual(plan.needsXMP.map(\.stem).sorted(), ["A", "C"])
    }

    // MARK: - missing fingerprint = miss

    func test_missingFingerprint_treatedAsCacheMiss() {
        let entries = [entry("A")]
        // No fingerprint for "A".
        let plan = IndexingWorkPlan.make(
            shoot: makeShoot(entries: entries),
            fingerprints: [:],
            cache: makeCache(),
            xmpStems: [])
        XCTAssertEqual(plan.needsBasicFetch.map(\.stem), ["A"])
        XCTAssertEqual(plan.needsAdvancedExif.map(\.stem), ["A"])
        XCTAssertTrue(plan.cachedThumbBytes.isEmpty)
    }
}
