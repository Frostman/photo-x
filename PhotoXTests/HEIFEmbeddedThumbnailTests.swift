import XCTest
import ImageIO
@testable import PhotoX

/// Coverage for HEIFEmbeddedThumbnail's ISOBMFF box parser. Both
/// synthesised-bytes unit tests (drive the parser through specific
/// box shapes) and one integration test against a real Sony HIF in
/// the sample/ folder (validates we actually find the right item in
/// a production file).
final class HEIFEmbeddedThumbnailTests: XCTestCase {

    // MARK: - byte helpers

    /// 4-byte big-endian uint32.
    private static func u32(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
    /// 2-byte big-endian uint16.
    private static func u16(_ v: UInt16) -> Data {
        var be = v.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
    private static func ascii(_ s: String) -> Data { Data(s.utf8) }

    /// Build one ISOBMFF box: size(4) + type(4) + body.
    private static func box(_ type: String, _ body: Data) -> Data {
        var out = u32(UInt32(8 + body.count))
        out.append(ascii(type))
        out.append(body)
        return out
    }

    /// `infe` v2 box body: version+flags(4) + item_id(2) +
    /// protection(2) + item_type(4) + item_name(\0).
    private static func infe(itemID: UInt16, type: String) -> Data {
        var b = Data()
        b.append(2)               // version 2
        b.append(contentsOf: [0, 0, 0])  // flags
        b.append(u16(itemID))
        b.append(u16(0))          // protection_index
        b.append(ascii(type))
        b.append(0)               // empty item_name terminator
        return box("infe", b)
    }

    /// Minimal `iinf` body that contains the given infe entries.
    /// version=0 so count is 2 bytes.
    private static func iinf(_ entries: [Data]) -> Data {
        var b = Data()
        b.append(0)                          // version 0
        b.append(contentsOf: [0, 0, 0])      // flags
        b.append(u16(UInt16(entries.count))) // count (2 bytes for v0)
        for e in entries { b.append(e) }
        return box("iinf", b)
    }

    /// Minimal `iloc` body for v0 with 1 item, 4-byte offset + 4-byte
    /// length, no base_offset, no index. The sizes nibble pair is
    /// constructed so offset/length = 4 each, base_offset = 0,
    /// index_size = 0 (reserved for v0).
    private static func iloc(itemID: UInt16, offset: UInt32, length: UInt32,
                             extraExtents: [(offset: UInt32, length: UInt32)] = []) -> Data {
        var b = Data()
        b.append(0)                          // version 0
        b.append(contentsOf: [0, 0, 0])      // flags
        // sizes nibbles: (offset_size << 4 | length_size) then (base_offset_size << 4 | reserved)
        b.append(UInt8((4 << 4) | 4))        // offset=4, length=4
        b.append(UInt8((0 << 4) | 0))        // base_offset=0, reserved=0
        b.append(u16(1))                     // item_count (1)
        // item record:
        b.append(u16(itemID))                // item_id
        // no version>=1 reserved+construction_method field
        b.append(u16(0))                     // data_reference_index
        // base_offset omitted (size=0)
        let extentCount = 1 + extraExtents.count
        b.append(u16(UInt16(extentCount)))   // extent_count
        b.append(u32(offset))                // first extent_offset
        b.append(u32(length))                // first extent_length
        for ex in extraExtents {
            b.append(u32(ex.offset))
            b.append(u32(ex.length))
        }
        return box("iloc", b)
    }

    /// `meta` is a FullBox: 1B version + 3B flags + nested boxes.
    private static func meta(_ children: [Data]) -> Data {
        var b = Data()
        b.append(0)                       // version
        b.append(contentsOf: [0, 0, 0])   // flags
        for c in children { b.append(c) }
        return box("meta", b)
    }

    /// `ftyp` body. Just enough to look like a valid HEIF file header.
    private static let ftyp: Data = {
        var b = Data()
        b.append(ascii("heic"))           // major brand
        b.append(u32(0))                  // minor version
        b.append(ascii("mif1"))           // compat brands
        b.append(ascii("heic"))
        return box("ftyp", b)
    }()

    // MARK: - parser tests

    func test_locateJPEGThumbnail_singleJpegItem_returnsItsExtent() {
        let file = Self.ftyp + Self.meta([
            Self.iinf([Self.infe(itemID: 7, type: "jpeg")]),
            Self.iloc(itemID: 7, offset: 0x1000, length: 0x800),
        ])
        let loc = HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: file)
        XCTAssertEqual(loc, HEIFEmbeddedThumbnail.ItemLocation(offset: 0x1000, length: 0x800))
    }

    func test_locateJPEGThumbnail_picksJpegOverHvc1() {
        let file = Self.ftyp + Self.meta([
            Self.iinf([
                Self.infe(itemID: 1, type: "hvc1"),
                Self.infe(itemID: 2, type: "jpeg"),
                Self.infe(itemID: 3, type: "hvc1"),
            ]),
            Self.iloc(itemID: 2, offset: 0x2600, length: 0x2000),
        ])
        let loc = HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: file)
        XCTAssertEqual(loc, HEIFEmbeddedThumbnail.ItemLocation(offset: 0x2600, length: 0x2000))
    }

    func test_locateJPEGThumbnail_noMetaBox_returnsNil() {
        // Just ftyp, no meta.
        XCTAssertNil(HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: Self.ftyp))
    }

    func test_locateJPEGThumbnail_metaWithoutIINF_returnsNil() {
        let file = Self.ftyp + Self.meta([
            Self.iloc(itemID: 99, offset: 0, length: 0),
            // no iinf — we can't know which item is jpeg
        ])
        XCTAssertNil(HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: file))
    }

    func test_locateJPEGThumbnail_metaWithoutILOC_returnsNil() {
        let file = Self.ftyp + Self.meta([
            Self.iinf([Self.infe(itemID: 1, type: "jpeg")]),
            // no iloc — we know the id but not where to find bytes
        ])
        XCTAssertNil(HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: file))
    }

    func test_locateJPEGThumbnail_multipleExtents_returnsFirstOnly() {
        let file = Self.ftyp + Self.meta([
            Self.iinf([Self.infe(itemID: 5, type: "jpeg")]),
            Self.iloc(itemID: 5, offset: 0x1000, length: 0x800,
                      extraExtents: [(0x2000, 0x800), (0x3000, 0x800)]),
        ])
        let loc = HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: file)
        XCTAssertEqual(loc, HEIFEmbeddedThumbnail.ItemLocation(offset: 0x1000, length: 0x800))
    }

    func test_locateJPEGThumbnail_iinfBeforeOrAfterILOC_bothWork() {
        let file1 = Self.ftyp + Self.meta([
            Self.iinf([Self.infe(itemID: 9, type: "jpeg")]),
            Self.iloc(itemID: 9, offset: 0x4000, length: 0x100),
        ])
        let file2 = Self.ftyp + Self.meta([
            Self.iloc(itemID: 9, offset: 0x4000, length: 0x100),
            Self.iinf([Self.infe(itemID: 9, type: "jpeg")]),
        ])
        let expected = HEIFEmbeddedThumbnail.ItemLocation(offset: 0x4000, length: 0x100)
        XCTAssertEqual(HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: file1), expected)
        XCTAssertEqual(HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: file2), expected)
    }

    func test_locateJPEGThumbnail_garbageBytesReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertNil(HEIFEmbeddedThumbnail.locateJPEGThumbnail(in: garbage))
    }

    // MARK: - byte helpers (sanity)

    func test_readU32_bigEndian() {
        let d = Data([0x01, 0x02, 0x03, 0x04, 0xFF])
        XCTAssertEqual(HEIFEmbeddedThumbnail.readU32(d, at: 0), 0x01020304)
    }

    func test_readU16_bigEndian() {
        let d = Data([0x12, 0x34])
        XCTAssertEqual(HEIFEmbeddedThumbnail.readU16(d, at: 0), 0x1234)
    }

    // MARK: - integration against the real sample HIF

    func test_extract_realSonyHIF_returnsValidJPEGThumbnail() throws {
        let url = RepoSample.url.appendingPathComponent("DSC04207.HIF")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("sample HIF not available; skipping integration test")
        }
        guard let extracted = try HEIFEmbeddedThumbnail.extract(from: url) else {
            XCTFail("extract returned nil for a known Sony HIF with embedded JPEG")
            return
        }
        let bytes = extracted.jpeg
        XCTAssertGreaterThan(bytes.count, 1024, "expected non-trivial JPEG payload")
        XCTAssertLessThan(bytes.count, 64 * 1024, "Sony A1 II thumb is ~8 KB; allow some slack")
        // JPEG SOI marker.
        XCTAssertEqual(bytes[bytes.startIndex],     0xFF)
        XCTAssertEqual(bytes[bytes.startIndex + 1], 0xD8)
        XCTAssertEqual(bytes[bytes.startIndex + 2], 0xFF)
        // Decode it — should yield a CGImage at ~160×120 (Sony's
        // canonical embedded-thumb size).
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            XCTFail("CGImageSource couldn't decode the extracted thumbnail bytes")
            return
        }
        XCTAssertEqual(img.width, 160)
        XCTAssertEqual(img.height, 120)
        // Landscape shot: HEIF irot should report 0 → EXIF orientation 1.
        XCTAssertEqual(extracted.exifOrientation, 1,
                       "landscape Sony A1 II shot should have EXIF orientation 1")
    }

    func test_extract_realSonyHIF_returnsValidExifBytes() throws {
        let url = RepoSample.url.appendingPathComponent("DSC04207.HIF")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("sample HIF not available")
        }
        guard let extracted = try HEIFEmbeddedThumbnail.extract(from: url) else {
            XCTFail("extract returned nil")
            return
        }
        guard let exifBytes = extracted.exifBytes else {
            XCTFail("expected exifBytes from a known Sony HIF")
            return
        }
        XCTAssertGreaterThan(exifBytes.count, 100,
                             "Sony Exif block is normally a few KB")
        // First byte after the 4-byte prefix is stripped should be the
        // TIFF byte-order marker: 'I' (little-endian) or 'M' (big-endian).
        let first = exifBytes[exifBytes.startIndex]
        XCTAssertTrue(first == 0x49 || first == 0x4D,
                      "Exif bytes should start with II or MM, got 0x\(String(first, radix: 16))")
    }

    func test_extract_realSonyPortraitHIF_returnsCorrectOrientation() throws {
        let url = RepoSample.url.appendingPathComponent("DSC08866.HIF")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("portrait sample HIF not available; skipping")
        }
        guard let extracted = try HEIFEmbeddedThumbnail.extract(from: url) else {
            XCTFail("extract returned nil")
            return
        }
        // This shot was identified as Sony:CameraOrientation = 8 (90° CCW
        // from sensor). The HEIF irot box should match → EXIF orientation 8.
        XCTAssertEqual(extracted.exifOrientation, 8,
                       "portrait Sony shot with CameraOrientation=8 should map to EXIF 8")
    }

    // MARK: - irot box parsing (synthesised)

    /// Build a minimal `irot` property box wrapped in `iprp/ipco`.
    private static func iprpWithIROT(angle: UInt8) -> Data {
        let irot = box("irot", Data([angle & 0x03]))
        let ipco = box("ipco", irot)
        return box("iprp", ipco)
    }

    func test_locateOrientation_iROT_0_returnsExif1() {
        let file = Self.ftyp + Self.meta([Self.iprpWithIROT(angle: 0)])
        XCTAssertEqual(HEIFEmbeddedThumbnail.locateOrientation(in: file), 1)
    }

    func test_locateOrientation_iROT_1_returnsExif8() {
        // 90° CCW = EXIF 8.
        let file = Self.ftyp + Self.meta([Self.iprpWithIROT(angle: 1)])
        XCTAssertEqual(HEIFEmbeddedThumbnail.locateOrientation(in: file), 8)
    }

    func test_locateOrientation_iROT_2_returnsExif3() {
        // 180° = EXIF 3.
        let file = Self.ftyp + Self.meta([Self.iprpWithIROT(angle: 2)])
        XCTAssertEqual(HEIFEmbeddedThumbnail.locateOrientation(in: file), 3)
    }

    func test_locateOrientation_iROT_3_returnsExif6() {
        // 270° CCW = 90° CW = EXIF 6.
        let file = Self.ftyp + Self.meta([Self.iprpWithIROT(angle: 3)])
        XCTAssertEqual(HEIFEmbeddedThumbnail.locateOrientation(in: file), 6)
    }

    func test_locateOrientation_noIROT_returnsNil() {
        let file = Self.ftyp + Self.meta([
            Self.iinf([Self.infe(itemID: 1, type: "jpeg")]),
            Self.iloc(itemID: 1, offset: 0, length: 0),
        ])
        XCTAssertNil(HEIFEmbeddedThumbnail.locateOrientation(in: file))
    }
}
