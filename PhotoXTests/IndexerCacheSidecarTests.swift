import XCTest
import IndexingCore
@testable import PhotoX

/// Pins down the two-payload behaviour of IndexerCache:
///   - No sidecar present → behaves exactly like the pre-cutover
///     single-payload cache (any change here is a regression in
///     the "indexer behavior is 100% the same" guarantee the user
///     asked for explicitly).
///   - Sidecar present → reads win from sidecar; writes still go
///     to the local payload; sidecar file is never rewritten.
///
/// Companion to `IndexerCacheTests.swift`, which exercises the
/// schema, GC, prune, and disk-roundtrip paths that don't depend
/// on the sidecar at all.
@MainActor
final class IndexerCacheSidecarTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IndexerCacheSidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
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

    private func makeSourceFile(name: String, bytes: Int = 64) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    private func writeSidecar(_ index: ShootSidecarIndex) throws {
        try SidecarWriter.write(index, to: tempDir)
    }

    // MARK: - No sidecar: parity with pre-cutover behaviour

    /// loadSidecar is a no-op when no .photox-index.plist exists.
    /// Cache state stays empty; subsequent reads go straight to
    /// the local payload.
    func test_noSidecar_loadSidecarIsNoOp() async throws {
        let cache = IndexerCache(shootFolder: tempDir)
        XCTAssertNil(cache.sidecarPayload)
        XCTAssertEqual(cache.sidecarEntryCount, 0)

        await cache.loadSidecar()

        XCTAssertNil(cache.sidecarPayload,
                     "no sidecar file → sidecarPayload stays nil")
        XCTAssertEqual(cache.sidecarEntryCount, 0)
        XCTAssertNil(cache.sidecarIndexedAt)
        XCTAssertNil(cache.sidecarIndexerVersion)
    }

    /// With no sidecar, every cache hit reports source == .localCache —
    /// matches the pre-cutover "all hits come from Library/Caches"
    /// behaviour exactly.
    func test_noSidecar_hitsAreLocalCache() async throws {
        let source = try makeSourceFile(name: "DSC04207.HIF")
        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()  // no-op

        let fp = try IndexerCache.fingerprint(of: source)
        cache.updateEntry(stem: "DSC04207", fingerprint: fp,
                          exif: ExifSummary(camera: "Sony α1 II"),
                          sequenceNumber: 3)

        let hit = try XCTUnwrap(cache.entry(for: "DSC04207", fingerprint: fp))
        XCTAssertEqual(hit.source, .localCache,
                       "all hits come from local cache when no sidecar exists")
        XCTAssertEqual(hit.exif?.camera, "Sony α1 II")
        XCTAssertEqual(hit.sequenceNumber, 3)
    }

    /// updateEntry writes through to the local payload when no
    /// sidecar exists. flush() must produce the same on-disk plist
    /// as before the cutover.
    func test_noSidecar_flushRoundTrip() async throws {
        let source = try makeSourceFile(name: "DSC04208.HIF")
        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()  // no-op

        let fp = try IndexerCache.fingerprint(of: source)
        cache.updateEntry(stem: "DSC04208", fingerprint: fp,
                          exif: ExifSummary(camera: "Sony α1 II"),
                          sequenceNumber: 7)
        await cache.flush()

        // Sanity: the on-disk file decodes as the historical
        // Payload shape — the field ordering and Codable types
        // must NOT have drifted under the rename to LocalPayload.
        let url = IndexerCache.cacheURL(for: tempDir)
        let data = try Data(contentsOf: url)
        let decoded = try PropertyListDecoder().decode(
            IndexerCache.Payload.self, from: data)
        XCTAssertEqual(decoded.version, IndexerCache.currentSchemaVersion)
        XCTAssertEqual(decoded.entries["DSC04208"]?.sequenceNumber, 7)
    }

    /// On a re-open (fresh IndexerCache against the same folder)
    /// the local payload is read from disk and entries are still
    /// reachable as cache hits. Pre-cutover invariant: warm reopen
    /// finds every entry that was flushed.
    func test_noSidecar_reopenRehydratesLocal() async throws {
        let source = try makeSourceFile(name: "DSC04209.HIF")
        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()
        let fp = try IndexerCache.fingerprint(of: source)
        cache.updateEntry(stem: "DSC04209", fingerprint: fp,
                          sequenceNumber: 11)
        await cache.flush()

        // Fresh cache against the same shoot.
        let reread = IndexerCache(shootFolder: tempDir)
        await reread.loadSidecar()  // no-op

        let hit = try XCTUnwrap(reread.entry(for: "DSC04209", fingerprint: fp))
        XCTAssertEqual(hit.source, .localCache)
        XCTAssertEqual(hit.sequenceNumber, 11)
    }

    // MARK: - Sidecar present: new behaviour

    /// A matching sidecar entry is hit as `.sidecar`. The local
    /// payload doesn't get involved — caller never even touches it.
    func test_withSidecar_hitsAreSidecar() async throws {
        let source = try makeSourceFile(name: "DSC04210.HIF")
        let fp = try IndexerCache.fingerprint(of: source)

        let sidecar = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(timeIntervalSince1970: 1_700_000_000),
            indexerVersion: "test-producer",
            entries: ["DSC04210": IndexEntry(
                fingerprint: fp,
                exif: ExifSummary(camera: "Sony α1 II from sidecar"),
                sequenceNumber: 99)]
        )
        try writeSidecar(sidecar)

        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()
        XCTAssertEqual(cache.sidecarEntryCount, 1)
        XCTAssertEqual(cache.sidecarIndexedAt,
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(cache.sidecarIndexerVersion, "test-producer")

        let hit = try XCTUnwrap(cache.entry(for: "DSC04210", fingerprint: fp))
        XCTAssertEqual(hit.source, .sidecar)
        XCTAssertEqual(hit.exif?.camera, "Sony α1 II from sidecar")
        XCTAssertEqual(hit.sequenceNumber, 99)
    }

    /// Sidecar wins when both layers have a matching fingerprint
    /// for the same stem (producer is source of truth).
    func test_withSidecar_sidecarBeatsLocal() async throws {
        let source = try makeSourceFile(name: "DSC04211.HIF")
        let fp = try IndexerCache.fingerprint(of: source)

        // Local cache writes "from local" first.
        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()  // no-op (no sidecar yet)
        cache.updateEntry(stem: "DSC04211", fingerprint: fp,
                          exif: ExifSummary(camera: "from local"))
        await cache.flush()

        // Now a sidecar lands with a different value for the same
        // stem + fingerprint.
        let sidecar = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(),
            indexerVersion: "test",
            entries: ["DSC04211": IndexEntry(
                fingerprint: fp,
                exif: ExifSummary(camera: "from sidecar"))]
        )
        try writeSidecar(sidecar)

        let reread = IndexerCache(shootFolder: tempDir)
        await reread.loadSidecar()
        let hit = try XCTUnwrap(reread.entry(for: "DSC04211", fingerprint: fp))
        XCTAssertEqual(hit.source, .sidecar,
                       "sidecar must win when both layers have a match")
        XCTAssertEqual(hit.exif?.camera, "from sidecar")
    }

    /// Stems missing from the sidecar fall through to the local
    /// payload. Critical for "files added after the NAS run" —
    /// macOS picks them up via the normal indexer path.
    func test_withSidecar_missingStemFallsThroughToLocal() async throws {
        let sourceA = try makeSourceFile(name: "DSC04212.HIF")
        let sourceB = try makeSourceFile(name: "DSC04213.HIF")
        let fpA = try IndexerCache.fingerprint(of: sourceA)
        let fpB = try IndexerCache.fingerprint(of: sourceB)

        // Sidecar only covers A.
        let sidecar = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(),
            indexerVersion: "test",
            entries: ["DSC04212": IndexEntry(
                fingerprint: fpA,
                exif: ExifSummary(camera: "A from sidecar"))]
        )
        try writeSidecar(sidecar)

        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()
        // B gets indexed by macOS post-sidecar.
        cache.updateEntry(stem: "DSC04213", fingerprint: fpB,
                          exif: ExifSummary(camera: "B from local"))

        let aHit = try XCTUnwrap(cache.entry(for: "DSC04212", fingerprint: fpA))
        XCTAssertEqual(aHit.source, .sidecar)
        XCTAssertEqual(aHit.exif?.camera, "A from sidecar")

        let bHit = try XCTUnwrap(cache.entry(for: "DSC04213", fingerprint: fpB))
        XCTAssertEqual(bHit.source, .localCache)
        XCTAssertEqual(bHit.exif?.camera, "B from local")
    }

    /// updateEntry is a no-op when the sidecar already covers this
    /// stem with a matching fingerprint — avoids ~100 MB local-plist
    /// rewrites on every shoot open of a sidecar-covered shoot.
    func test_withSidecar_updateForCoveredEntryIsNoOp() async throws {
        let source = try makeSourceFile(name: "DSC04214.HIF")
        let fp = try IndexerCache.fingerprint(of: source)

        let sidecar = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(),
            indexerVersion: "test",
            entries: ["DSC04214": IndexEntry(fingerprint: fp,
                                              sequenceNumber: 1)]
        )
        try writeSidecar(sidecar)

        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()

        // Re-write the same stem locally — should NOT touch the
        // local payload or mark dirty.
        XCTAssertEqual(cache.entryCount, 0,
                       "local payload starts empty")
        cache.updateEntry(stem: "DSC04214", fingerprint: fp,
                          sequenceNumber: 99)
        XCTAssertEqual(cache.entryCount, 0,
                       "updateEntry for a sidecar-covered stem must not write to local")
    }

    /// Fingerprint divergence between sidecar and live file falls
    /// through to local (the file changed since the NAS index).
    func test_withSidecar_fingerprintMismatchFallsThrough() async throws {
        let source = try makeSourceFile(name: "DSC04215.HIF", bytes: 64)
        let oldFP = try IndexerCache.fingerprint(of: source)

        let sidecar = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(),
            indexerVersion: "test",
            entries: ["DSC04215": IndexEntry(fingerprint: oldFP,
                                              sequenceNumber: 1)]
        )
        try writeSidecar(sidecar)

        // Mutate the file after the sidecar was produced.
        try Data(count: 128).write(to: source)
        let newFP = try IndexerCache.fingerprint(of: source)
        XCTAssertNotEqual(oldFP, newFP)

        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()
        XCTAssertNil(cache.entry(for: "DSC04215", fingerprint: newFP),
                     "stale-fingerprint sidecar entry must miss")

        // Local re-index should now succeed (sidecar-covered check
        // also requires matching fingerprint, so the entry is
        // treated as uncovered).
        cache.updateEntry(stem: "DSC04215", fingerprint: newFP,
                          sequenceNumber: 42)
        let hit = try XCTUnwrap(cache.entry(for: "DSC04215", fingerprint: newFP))
        XCTAssertEqual(hit.source, .localCache)
        XCTAssertEqual(hit.sequenceNumber, 42)
    }

    /// flush() never rewrites the sidecar file — the producer
    /// owns it. After updateEntry + flush, the sidecar bytes on
    /// disk must be byte-identical to what we wrote initially.
    func test_withSidecar_flushDoesNotRewriteSidecar() async throws {
        let source = try makeSourceFile(name: "DSC04216.HIF")
        let fp = try IndexerCache.fingerprint(of: source)
        let sidecar = ShootSidecarIndex(
            version: ShootSidecarIndex.currentSchemaVersion,
            indexedAt: Date(timeIntervalSince1970: 1_700_000_000),
            indexerVersion: "test",
            entries: ["DSC04216": IndexEntry(fingerprint: fp,
                                              sequenceNumber: 1)]
        )
        try writeSidecar(sidecar)
        let sidecarURL = SidecarFile.url(in: tempDir)
        let bytesBefore = try Data(contentsOf: sidecarURL)

        let cache = IndexerCache(shootFolder: tempDir)
        await cache.loadSidecar()
        // Touch a different stem — write goes to local only.
        let source2 = try makeSourceFile(name: "DSC04217.HIF")
        let fp2 = try IndexerCache.fingerprint(of: source2)
        cache.updateEntry(stem: "DSC04217", fingerprint: fp2,
                          sequenceNumber: 2)
        await cache.flush()

        let bytesAfter = try Data(contentsOf: sidecarURL)
        XCTAssertEqual(bytesBefore, bytesAfter,
                       "sidecar plist must never be rewritten by the macOS app")
    }
}
