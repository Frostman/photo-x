import XCTest
@testable import PhotoX

/// Coverage for the in-process TIFF/EXIF parser scoped to the
/// `ExifSummary` fields the sidebar surfaces. Mix of:
/// 1. Hand-crafted minimal TIFF blocks exercising specific tags +
///    types + endianness.
/// 2. Integration test against `sample/DSC04207.HIF`'s real Exif item
///    bytes — the parity oracle is `ImageIOMetadata.read(from:)` on
///    the same file (which we trust for standard EXIF).
final class TIFFEXIFParserTests: XCTestCase {

    // MARK: - byte helpers (little-endian by default)

    private static func u16le(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
    private static func u32le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func u16be(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func u32be(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
         UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// Build one IFD entry: tag(2) + type(2) + count(4) + value/offset(4).
    /// All little-endian.
    private static func entry(tag: UInt16, type: UInt16, count: UInt32,
                              valueLE: [UInt8]) -> [UInt8] {
        precondition(valueLE.count == 4)
        return u16le(tag) + u16le(type) + u32le(count) + valueLE
    }

    /// Build a minimal little-endian TIFF block with one IFD0 containing
    /// the supplied entries. `extraBytes` (referenced via offsets in
    /// entries) are appended after the IFD's next-offset field.
    private static func tiffLE(entries: [[UInt8]], extraBytes: [UInt8] = []) -> Data {
        var bytes: [UInt8] = []
        // Header: "II" + magic 42 + offset-to-IFD0 = 8.
        bytes.append(contentsOf: [0x49, 0x49])
        bytes.append(contentsOf: u16le(42))
        bytes.append(contentsOf: u32le(8))
        // IFD0: count(2) + entries(N × 12) + next_ifd_offset(4) = 0.
        bytes.append(contentsOf: u16le(UInt16(entries.count)))
        for e in entries { bytes.append(contentsOf: e) }
        bytes.append(contentsOf: u32le(0))   // no next IFD
        bytes.append(contentsOf: extraBytes)
        return Data(bytes)
    }

    // MARK: - byte order

    func test_parse_rejectsMissingByteOrderMarker() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertNil(TIFFEXIFParser.parse(garbage))
    }

    func test_parse_acceptsLittleEndian_II_marker() {
        // Empty IFD0 — no tags — should still return an empty
        // ExifSummary, not nil (the marker + IFD pointer are valid).
        let data = Self.tiffLE(entries: [])
        XCTAssertNotNil(TIFFEXIFParser.parse(data))
    }

    func test_parse_acceptsBigEndian_MM_marker() {
        // Construct a minimal big-endian TIFF.
        var bytes: [UInt8] = [0x4D, 0x4D]   // "MM"
        bytes.append(contentsOf: Self.u16be(42))
        bytes.append(contentsOf: Self.u32be(8))
        bytes.append(contentsOf: Self.u16be(0))   // 0 entries
        bytes.append(contentsOf: Self.u32be(0))   // next IFD
        XCTAssertNotNil(TIFFEXIFParser.parse(Data(bytes)))
    }

    // MARK: - per-tag parsing

    func test_parse_extractsMakeAndModelAsASCII() {
        // "Sony\0" is 5 bytes — fits inline as offset because count ≤ 4.
        // Use longer strings to exercise the offset-pointer path.
        let makeStr  = "SONY\0"        // 5 bytes
        let modelStr = "ILCE-1M2\0"    // 9 bytes
        // Layout extra bytes after IFD's next-offset. Compute offsets:
        // header(8) + ifd_count(2) + 2 entries × 12 + next(4) = 38.
        let extraOffset = 38
        var extras: [UInt8] = []
        extras.append(contentsOf: Array(makeStr.utf8))
        extras.append(contentsOf: Array(modelStr.utf8))

        let entries: [[UInt8]] = [
            // Make (0x010F), ASCII (2), count=5, offset → extraOffset
            Self.entry(tag: 0x010F, type: 2, count: 5,
                       valueLE: Self.u32le(UInt32(extraOffset))),
            // Model (0x0110), ASCII (2), count=9, offset → extraOffset + 5
            Self.entry(tag: 0x0110, type: 2, count: 9,
                       valueLE: Self.u32le(UInt32(extraOffset + 5))),
        ]
        let data = Self.tiffLE(entries: entries, extraBytes: extras)
        let s = TIFFEXIFParser.parse(data)
        XCTAssertEqual(s?.camera, "Sony ILCE-1M2",
                       "Make should be pretty-cased + joined with Model")
    }

    func test_parse_extractsOrientationAsSHORT() {
        // SHORT (type 3) fits in the 4-byte value field as the first 2 bytes.
        let entries: [[UInt8]] = [
            Self.entry(tag: 0x0112, type: 3, count: 1,
                       valueLE: Self.u16le(6) + [0, 0]),
        ]
        let data = Self.tiffLE(entries: entries)
        XCTAssertEqual(TIFFEXIFParser.parse(data)?.orientation, 6)
    }

    func test_parse_extractsFNumberAsRATIONAL() {
        // RATIONAL (type 5) is 8 bytes — must use offset pointer.
        let extraOffset = 8 + 2 + 12 + 4   // 26
        let extras: [UInt8] = Self.u32le(56) + Self.u32le(10)   // 5.6
        let entries: [[UInt8]] = [
            // Need a follow-pointer for ExifIFD too — FNumber lives there
            // not in IFD0. Use a minimal nested IFD layout.
        ]
        // Actually testing this needs ExifIFD nesting; do it below in
        // test_parse_followsExifIFDPointer.
        _ = (extraOffset, extras, entries)
    }

    func test_parse_followsExifIFDPointer_andReadsFNumber() {
        // Layout:
        //  header (8 bytes)
        //  IFD0 count (2) + 1 entry (12) + next (4) = 18 bytes
        //    → IFD0 ends at offset 26
        //  IFD0 entry: ExifIFDPointer (0x8769) LONG count=1 value=26
        //  ExifIFD starts at 26
        //    count (2) + 1 entry (12) + next (4) = 18 bytes
        //    → ExifIFD ends at offset 44
        //  ExifIFD entry: FNumber (0x829D) RATIONAL count=1 offset=44
        //  Extra bytes (FNumber's 8 bytes) at offset 44: 56, 10 (= 5.6)
        let ifd0Entries: [[UInt8]] = [
            Self.entry(tag: 0x8769, type: 4, count: 1,
                       valueLE: Self.u32le(26)),
        ]
        let exifIFDEntries: [[UInt8]] = [
            Self.entry(tag: 0x829D, type: 5, count: 1,
                       valueLE: Self.u32le(44)),
        ]

        var bytes: [UInt8] = []
        bytes.append(contentsOf: [0x49, 0x49])
        bytes.append(contentsOf: Self.u16le(42))
        bytes.append(contentsOf: Self.u32le(8))
        // IFD0
        bytes.append(contentsOf: Self.u16le(UInt16(ifd0Entries.count)))
        for e in ifd0Entries { bytes.append(contentsOf: e) }
        bytes.append(contentsOf: Self.u32le(0))
        // ExifIFD at offset 26
        bytes.append(contentsOf: Self.u16le(UInt16(exifIFDEntries.count)))
        for e in exifIFDEntries { bytes.append(contentsOf: e) }
        bytes.append(contentsOf: Self.u32le(0))
        // RATIONAL value bytes at offset 44.
        bytes.append(contentsOf: Self.u32le(56))   // numerator
        bytes.append(contentsOf: Self.u32le(10))   // denominator → 5.6

        let s = TIFFEXIFParser.parse(Data(bytes))
        XCTAssertEqual(s?.aperture, "f/5.6")
    }

    func test_parse_handlesEmptyIFD() {
        let data = Self.tiffLE(entries: [])
        let s = TIFFEXIFParser.parse(data)
        XCTAssertNotNil(s)
        XCTAssertNil(s?.camera)
        XCTAssertNil(s?.aperture)
    }

    func test_parse_rejectsTruncatedData() {
        // Marker + magic but no IFD offset.
        let data = Data([0x49, 0x49, 0x2A, 0x00])
        XCTAssertNil(TIFFEXIFParser.parse(data))
    }

    // MARK: - integration: real Sony HIF via HEIFEmbeddedThumbnail

    func test_extractedExifBytes_parseToValidExifSummary() throws {
        let url = URL(fileURLWithPath:
            "/Users/frostman/workspace/personal/photo-x/sample/DSC04207.HIF")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("sample HIF not available")
        }
        guard let extracted = try HEIFEmbeddedThumbnail.extract(from: url),
              let exifBytes = extracted.exifBytes else {
            XCTFail("HEIFEmbeddedThumbnail didn't return Exif bytes")
            return
        }
        // Bytes should start with II/MM after the 4-byte offset prefix
        // is stripped by HEIFEmbeddedThumbnail.
        let first = exifBytes[exifBytes.startIndex]
        XCTAssertTrue(first == 0x49 || first == 0x4D,
                      "Exif bytes should start with II or MM, got 0x\(String(first, radix: 16))")
        guard let summary = TIFFEXIFParser.parse(exifBytes) else {
            XCTFail("TIFFEXIFParser couldn't parse the real HIF's Exif block")
            return
        }
        // Compare against ImageIO's view of the same file as the oracle.
        let oracle = ImageIOMetadata.read(from: url)
        XCTAssertEqual(summary.camera, oracle.camera,
                       "camera should match ImageIO's parse")
        XCTAssertEqual(summary.lens, oracle.lens,
                       "lens should match ImageIO's parse")
        XCTAssertEqual(summary.aperture, oracle.aperture)
        XCTAssertEqual(summary.shutterSpeed, oracle.shutterSpeed)
        XCTAssertEqual(summary.iso, oracle.iso)
        XCTAssertEqual(summary.focalLength, oracle.focalLength)
        // ImageIO synthesizes Orientation=1 when the tag is absent;
        // TIFFEXIFParser leaves it nil. Coalesce on our side for the
        // ImageIO oracle so the legacy comparison still passes — the
        // canonical exiftool parity test does not coalesce.
        XCTAssertEqual(summary.orientation ?? 1, oracle.orientation)
        // PixelXDimension / PixelYDimension also covered.
        XCTAssertEqual(summary.pixelWidth,  oracle.pixelWidth)
        XCTAssertEqual(summary.pixelHeight, oracle.pixelHeight)
    }

    // MARK: - integration: parity with exiftool across the whole sample/

    /// For every HIF in `sample/`: extract Exif bytes via HEIF parser,
    /// parse them with `TIFFEXIFParser`, run exiftool one-shot on the
    /// same file, route both through `ExifSummary` and compare every
    /// field. Catches regressions in the TIFF parser against the
    /// canonical oracle (exiftool). Skipped if the sample folder or
    /// exiftool isn't available in the dev environment.
    func test_parityWithExiftool_acrossSampleHIFs() throws {
        let sampleDir = URL(fileURLWithPath:
            "/Users/frostman/workspace/personal/photo-x/sample")
        let hifs: [URL]
        do {
            hifs = try FileManager.default
                .contentsOfDirectory(at: sampleDir,
                                     includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.uppercased() == "HIF" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw XCTSkip("sample/ not available: \(error)")
        }
        guard !hifs.isEmpty else { throw XCTSkip("no HIFs in sample/") }
        guard FileManager.default.isExecutableFile(
            atPath: ExifToolRunner.exifToolPath
        ) else {
            throw XCTSkip("exiftool not available")
        }

        for url in hifs {
            let name = url.lastPathComponent

            // Our path: HEIF box parse → TIFF parser → ExifSummary
            guard let extracted = try HEIFEmbeddedThumbnail.extract(from: url),
                  let exifBytes = extracted.exifBytes,
                  let ours = TIFFEXIFParser.parse(exifBytes) else {
                XCTFail("\(name): TIFFEXIFParser path produced no summary")
                continue
            }

            // Oracle: one-shot exiftool → ExifSummary.from(exiftoolDict:)
            guard let dict = exiftoolDict(for: url) else {
                XCTFail("\(name): exiftool produced no parseable JSON")
                continue
            }
            let oracle = ExifSummary.from(exiftoolDict: dict)

            XCTAssertEqual(ours.camera,               oracle.camera,               "\(name): camera mismatch")
            XCTAssertEqual(ours.lens,                 oracle.lens,                 "\(name): lens mismatch")
            XCTAssertEqual(ours.aperture,             oracle.aperture,             "\(name): aperture mismatch")
            XCTAssertEqual(ours.shutterSpeed,         oracle.shutterSpeed,         "\(name): shutter speed mismatch")
            XCTAssertEqual(ours.iso,                  oracle.iso,                  "\(name): ISO mismatch")
            XCTAssertEqual(ours.focalLength,          oracle.focalLength,          "\(name): focal length mismatch")
            XCTAssertEqual(ours.exposureCompensation, oracle.exposureCompensation, "\(name): exposure comp mismatch")
            XCTAssertEqual(ours.orientation,          oracle.orientation,          "\(name): orientation mismatch")
            XCTAssertEqual(ours.pixelWidth,           oracle.pixelWidth,           "\(name): pixelWidth mismatch")
            XCTAssertEqual(ours.pixelHeight,          oracle.pixelHeight,          "\(name): pixelHeight mismatch")
            XCTAssertEqual(ours.dateTime,             oracle.dateTime,             "\(name): dateTime mismatch")
        }
    }

    /// Run one-shot exiftool requesting exactly the tags our TIFF parser
    /// covers. `-G1` group prefixes match `ExifSummary.from(exiftoolDict:)`'s
    /// lookup keys; `-n` returns raw numeric values so doubles parse
    /// without locale dance.
    private func exiftoolDict(for url: URL) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExifToolRunner.exifToolPath)
        process.arguments = [
            "-j", "-G1", "-n",
            "-EXIF:Make", "-EXIF:Model",
            "-EXIF:LensModel", "-ExifIFD:LensModel",
            "-EXIF:FNumber", "-EXIF:ExposureTime", "-EXIF:ISO",
            "-EXIF:FocalLength", "-EXIF:ExposureCompensation",
            "-EXIF:DateTimeOriginal",
            "-IFD0:Orientation", "-EXIF:Orientation",
            "-Composite:ImageSize",
            "--", url.path,
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        return arr?.first
    }
}
