import XCTest
@testable import PhotoX

/// Round-trip + invariant coverage for the XMP sidecar writer/reader pair.
/// All tests run against real files in a per-test temp directory so the
/// atomic-write path actually exercises `Data.write(.atomic)`.
final class XMPSidecarTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmptests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: XMPSidecar value type

    func test_starCount_clampedTo5_andNilForNonPositive() {
        XCTAssertNil(XMPSidecar(rating: nil).starCount)
        XCTAssertNil(XMPSidecar(rating: 0).starCount)
        XCTAssertNil(XMPSidecar(rating: -1).starCount)
        XCTAssertEqual(XMPSidecar(rating: 3).starCount, 3)
        XCTAssertEqual(XMPSidecar(rating: 99).starCount, 5)
    }

    func test_isReject_only_for_rating_minus_one() {
        XCTAssertTrue(XMPSidecar(rating: -1).isReject)
        XCTAssertFalse(XMPSidecar(rating: 0).isReject)
        XCTAssertFalse(XMPSidecar(rating: 5).isReject)
        XCTAssertFalse(XMPSidecar().isReject)
    }

    func test_hasDecision_trueForRatingOrLabel() {
        XCTAssertFalse(XMPSidecar.empty.hasDecision)
        XCTAssertTrue(XMPSidecar(rating: 3, label: nil).hasDecision)
        XCTAssertTrue(XMPSidecar(rating: nil, label: "Red").hasDecision)
        XCTAssertFalse(XMPSidecar(rating: nil, label: "").hasDecision,
                       "Empty label is not a real label")
    }

    // MARK: writer/reader round-trip — pristine sidecar

    func test_writeRating_thenRead_roundTrips() throws {
        let pair = makePair("A")
        try XMPSidecarWriter.updateRating(4, for: pair)
        XCTAssertEqual(XMPSidecarReader.read(for: pair)?.rating, 4)
    }

    func test_writeReject_readsAsMinusOne() throws {
        let pair = makePair("A")
        try XMPSidecarWriter.updateRating(-1, for: pair)
        let xmp = XMPSidecarReader.read(for: pair)
        XCTAssertEqual(xmp?.rating, -1)
        XCTAssertEqual(xmp?.isReject, true)
    }

    func test_writeLabel_thenRead_roundTrips() throws {
        let pair = makePair("A")
        try XMPSidecarWriter.updateLabel("Red", for: pair)
        XCTAssertEqual(XMPSidecarReader.read(for: pair)?.label, "Red")
    }

    func test_clearRating_removesTag() throws {
        let pair = makePair("A")
        try XMPSidecarWriter.updateRating(5, for: pair)
        try XMPSidecarWriter.updateRating(nil, for: pair)
        XCTAssertNil(XMPSidecarReader.read(for: pair)?.rating)
    }

    func test_clearLabel_removesTag() throws {
        let pair = makePair("A")
        try XMPSidecarWriter.updateLabel("Green", for: pair)
        try XMPSidecarWriter.updateLabel(nil, for: pair)
        XCTAssertNil(XMPSidecarReader.read(for: pair)?.label)
    }

    // MARK: invariants

    func test_separateWrites_doNotClobberEachOther() throws {
        // The writer must read-modify-write — rating updates must not drop the
        // label and vice versa. This is the central correctness property.
        let pair = makePair("A")
        try XMPSidecarWriter.updateRating(4, for: pair)
        try XMPSidecarWriter.updateLabel("Blue", for: pair)
        let xmp = XMPSidecarReader.read(for: pair)
        XCTAssertEqual(xmp?.rating, 4)
        XCTAssertEqual(xmp?.label, "Blue")
    }

    func test_writes_preserveForeignTagsInExistingXMP() throws {
        // Simulate a sidecar that Lightroom (or another tool) wrote with a
        // foreign tag like xmp:CreatorTool=Lightroom + a custom xmp:keyword.
        // PhotoX must not drop it when updating just the rating.
        let pair = makePair("A")
        let existing = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
              <xmp:Label>Yellow</xmp:Label>
              <xmp:CreatorTool>Lightroom Classic 13.0</xmp:CreatorTool>
              <xmp:keyword>portrait</xmp:keyword>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try existing.write(to: xmpURL(for: pair), atomically: true, encoding: .utf8)

        try XMPSidecarWriter.updateRating(2, for: pair)

        let raw = try String(contentsOf: xmpURL(for: pair), encoding: .utf8)
        XCTAssertTrue(raw.contains("<xmp:keyword>portrait</xmp:keyword>"),
                      "Custom Lightroom tags must survive a rating update")
        XCTAssertTrue(raw.contains("Yellow"),
                      "Pre-existing label must survive a rating update")
        XCTAssertEqual(XMPSidecarReader.read(for: pair)?.rating, 2)
        XCTAssertEqual(XMPSidecarReader.read(for: pair)?.label, "Yellow")
    }

    // MARK: applyIntent

    func test_applyIntent_writesBothFieldsInOneCall() throws {
        let pair = makePair("A")
        let result = try XMPSidecarWriter.applyIntent(
            .setBoth(rating: 4, label: "Blue"),
            existingData: nil,
            cachedMTime: nil,
            for: pair
        )
        let xmp = XMPSidecarReader.read(for: pair)
        XCTAssertEqual(xmp?.rating, 4)
        XCTAssertEqual(xmp?.label, "Blue")
        XCTAssertFalse(result.newData.isEmpty,
                       "returned bytes must be the serialized XMP for the cache")
    }

    func test_applyIntent_skipsFieldsTheIntentDidNotTouch() throws {
        let pair = makePair("A")
        // Seed with rating + label.
        _ = try XMPSidecarWriter.applyIntent(
            .setBoth(rating: 3, label: "Green"),
            existingData: nil, cachedMTime: nil, for: pair
        )
        // Apply an intent that only sets the rating — label must
        // remain "Green" untouched.
        _ = try XMPSidecarWriter.applyIntent(
            .setRating(5),
            existingData: nil, cachedMTime: nil, for: pair
        )
        let xmp = XMPSidecarReader.read(for: pair)
        XCTAssertEqual(xmp?.rating, 5)
        XCTAssertEqual(xmp?.label, "Green",
                       "label untouched by the rating-only intent must survive")
    }

    func test_applyIntent_preservesForeignTags() throws {
        // The cache-hit path must NOT drop foreign tags. Seed an XMP
        // with a Lightroom-style keyword + CreatorTool, then apply
        // a rating-only intent passing the seeded bytes as cache.
        let pair = makePair("A")
        let existing = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
              <xmp:Label>Yellow</xmp:Label>
              <xmp:keyword>portrait</xmp:keyword>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try existing.write(to: xmpURL(for: pair), atomically: true, encoding: .utf8)

        let seededData = try Data(contentsOf: xmpURL(for: pair))
        let mtime = try xmpURL(for: pair)
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        _ = try XMPSidecarWriter.applyIntent(
            .setRating(2),
            existingData: seededData,
            cachedMTime: mtime,
            for: pair
        )

        let raw = try String(contentsOf: xmpURL(for: pair), encoding: .utf8)
        XCTAssertTrue(raw.contains("<xmp:keyword>portrait</xmp:keyword>"),
                      "Custom keyword must survive a rating-only applyIntent")
        XCTAssertTrue(raw.contains("Yellow"),
                      "Pre-existing label must survive")
        XCTAssertEqual(XMPSidecarReader.read(for: pair)?.rating, 2)
        XCTAssertEqual(XMPSidecarReader.read(for: pair)?.label, "Yellow")
    }

    func test_applyIntent_driftDetection_reReadsFromDisk() throws {
        // The cache is keyed by mtime. If the file changed on disk
        // since the cache was populated (another tool wrote it), the
        // next applyIntent call must drop the cache and re-read so
        // foreign mutations aren't silently lost.
        let pair = makePair("A")
        // First write — get a cache snapshot.
        let first = try XMPSidecarWriter.applyIntent(
            .setRating(3),
            existingData: nil, cachedMTime: nil, for: pair
        )
        // Externally rewrite the file with a foreign tag the cache
        // doesn't know about, bumping the mtime.
        Thread.sleep(forTimeInterval: 0.05)
        let external = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
              <xmp:Rating>3</xmp:Rating>
              <xmp:keyword>landscape</xmp:keyword>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try external.write(to: xmpURL(for: pair), atomically: true, encoding: .utf8)

        // Call applyIntent with the STALE cache from `first`. Drift
        // detection should notice mtime mismatch, re-read disk, and
        // preserve the foreign keyword.
        _ = try XMPSidecarWriter.applyIntent(
            .setRating(5),
            existingData: first.newData,
            cachedMTime: first.mtime,
            for: pair
        )
        let raw = try String(contentsOf: xmpURL(for: pair), encoding: .utf8)
        XCTAssertTrue(raw.contains("<xmp:keyword>landscape</xmp:keyword>"),
                      "Drift detection must re-read disk so foreign keyword survives")
        XCTAssertEqual(XMPSidecarReader.read(for: pair)?.rating, 5)
    }

    // MARK: SidecarIntent

    func test_sidecarIntent_hasWork_falseWhenAllFieldsUnchanged() {
        XCTAssertFalse(SidecarIntent().hasWork)
        XCTAssertTrue(SidecarIntent.setRating(5).hasWork)
        XCTAssertTrue(SidecarIntent.setRating(nil).hasWork,
                      "clearing a field is still work")
        XCTAssertTrue(SidecarIntent.setLabel("Red").hasWork)
    }

    func test_sidecarIntent_merge_otherSetFieldsWin() {
        var a = SidecarIntent.setRating(3)
        let b = SidecarIntent.setLabel("Red")
        a.merge(b)
        XCTAssertEqual(a.rating, .some(.some(3)),
                       "self's rating untouched by other (other.rating == .none)")
        XCTAssertEqual(a.label, .some(.some("Red")),
                       "other's label fills in")

        var c = SidecarIntent.setRating(2)
        let d = SidecarIntent.setRating(5)
        c.merge(d)
        XCTAssertEqual(c.rating, .some(.some(5)), "other's set field overrides")
    }

    func test_reader_nilForMissingFile() {
        let pair = makePair("Z")
        XCTAssertNil(XMPSidecarReader.read(for: pair))
    }

    func test_reader_emptyForMalformedXMP() throws {
        let pair = makePair("A")
        try "not xml".write(to: xmpURL(for: pair), atomically: true, encoding: .utf8)
        XCTAssertEqual(XMPSidecarReader.read(for: pair), .empty)
    }

    // MARK: helpers

    private func makePair(_ stem: String) -> PhotoEntry {
        PhotoEntry(
            rawURL: tmp.appendingPathComponent("\(stem).ARW"),
            previewURL: tmp.appendingPathComponent("\(stem).HIF"),
            stem: stem
        )
    }

    private func xmpURL(for entry: PhotoEntry) -> URL {
        entry.xmpURL
    }
}
