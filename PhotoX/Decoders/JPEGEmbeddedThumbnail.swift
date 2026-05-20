import Foundation

/// Header-only extractor for the IFD1 thumbnail + EXIF block from a
/// camera JPG. Mirrors `HEIFEmbeddedThumbnail` for HIF files — we
/// read the first ~256 KB of the JPG, walk SOI/APPn/SOS markers,
/// find the APP1 "Exif\0\0" segment, then walk the inner TIFF for
/// IFD0 orientation + IFD1 thumbnail byte range. The returned JPG
/// (typically ~160×120) decodes in ~5 ms vs ~30+ ms for ImageIO's
/// 1/8 DCT downsample of the full image.
///
/// Returns nil when the JPG has no APP1 EXIF (web-edited images,
/// some screenshot tools) or no IFD1 thumbnail. Caller falls back
/// to ImageIO's reduced-resolution decode in that case.
enum JPEGEmbeddedThumbnail {
    struct Extracted: Equatable {
        let jpeg: Data
        let exifOrientation: Int
        let exifBytes: Data?
    }

    /// JPG markers are well-defined and far simpler than HEIF's
    /// ISOBMFF. We read first 256 KB (camera JPGs put EXIF + IFD1
    /// thumb near the top), then scan for the APP1 marker.
    static func extract(from url: URL) throws -> Extracted? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // 256 KB is generous — Sony A1 II JPGs put APP1+thumb in
        // the first ~32 KB. If the IFD1 thumbnail offset points
        // past our window we bail and the caller falls back.
        let header = handle.readData(ofLength: 256 * 1024)
        return parse(header: header)
    }

    static func parse(header data: Data) -> Extracted? {
        guard data.count >= 4,
              data[data.startIndex]     == 0xFF,
              data[data.startIndex + 1] == 0xD8 else { return nil }   // SOI

        // Scan markers until we find APP1 EXIF or SOS (compressed data start).
        var i = data.startIndex + 2
        while i + 4 <= data.endIndex {
            guard data[i] == 0xFF else { return nil }
            let marker = data[i + 1]
            // Standalone markers (no length): SOI/EOI/RSTn — we
            // shouldn't hit these mid-stream but be defensive.
            if marker == 0xD8 || marker == 0xD9 { i += 2; continue }
            if marker == 0xDA { return nil }   // SOS — stopped before EXIF
            // Length is big-endian, includes the 2 length bytes.
            let len = (Int(data[i + 2]) << 8) | Int(data[i + 3])
            guard len >= 2, i + 2 + len <= data.endIndex else { return nil }
            let payloadStart = i + 4
            let payloadLen   = len - 2

            // APP1 EXIF: payload begins with "Exif\0\0" then TIFF.
            if marker == 0xE1, payloadLen > 6,
               data[payloadStart]     == 0x45,    // 'E'
               data[payloadStart + 1] == 0x78,    // 'x'
               data[payloadStart + 2] == 0x69,    // 'i'
               data[payloadStart + 3] == 0x66,    // 'f'
               data[payloadStart + 4] == 0x00,
               data[payloadStart + 5] == 0x00 {
                let tiffStart = payloadStart + 6
                let tiffEnd   = payloadStart + payloadLen
                let tiff = data.subdata(in: tiffStart ..< tiffEnd)
                return assemble(from: tiff)
            }

            i += 2 + len
        }
        return nil
    }

    // MARK: - inner TIFF walk

    /// Walks IFD0 + IFD1 inside the TIFF block. IFD0 yields the
    /// orientation tag; IFD1 yields the embedded JPEG's offset and
    /// length within the TIFF block.
    private static func assemble(from tiff: Data) -> Extracted? {
        guard tiff.count >= 8 else { return nil }
        let endian: Endian
        switch (tiff[tiff.startIndex], tiff[tiff.startIndex + 1]) {
        case (0x49, 0x49): endian = .little   // "II"
        case (0x4D, 0x4D): endian = .big      // "MM"
        default: return nil
        }
        guard read16(tiff, at: 2, endian) == 42 else { return nil }
        guard let ifd0Offset = read32(tiff, at: 4, endian).map(Int.init),
              ifd0Offset + 2 <= tiff.count else { return nil }

        // IFD0 walk: only care about Orientation (tag 0x0112) and
        // the next-IFD pointer (= IFD1).
        let (ifd0Entries, ifd1Offset) = walkIFD(tiff, at: ifd0Offset, endian: endian)
        let orientation = (ifd0Entries[0x0112]?.first).map(Int.init) ?? 1

        guard let ifd1Offset, ifd1Offset + 2 <= tiff.count else {
            // No IFD1 → no embedded thumbnail. Return the EXIF
            // anyway so the sidebar can still populate from this
            // pass instead of waiting for exiftool.
            return Extracted(jpeg: Data(), exifOrientation: orientation, exifBytes: tiff)
        }

        let (ifd1Entries, _) = walkIFD(tiff, at: ifd1Offset, endian: endian)
        // 0x0201 = JPEGInterchangeFormat (offset to thumb JPG within TIFF).
        // 0x0202 = JPEGInterchangeFormatLength.
        guard let jpegOff = (ifd1Entries[0x0201]?.first).map(Int.init),
              let jpegLen = (ifd1Entries[0x0202]?.first).map(Int.init),
              jpegLen > 0,
              jpegOff + jpegLen <= tiff.count else {
            return Extracted(jpeg: Data(), exifOrientation: orientation, exifBytes: tiff)
        }
        let jpeg = tiff.subdata(in: jpegOff ..< (jpegOff + jpegLen))
        // Sanity-check the SOI — a malformed IFD1 entry would
        // otherwise hand the decoder garbage.
        guard jpeg.count >= 2,
              jpeg[jpeg.startIndex] == 0xFF,
              jpeg[jpeg.startIndex + 1] == 0xD8 else {
            return Extracted(jpeg: Data(), exifOrientation: orientation, exifBytes: tiff)
        }
        return Extracted(jpeg: jpeg, exifOrientation: orientation, exifBytes: tiff)
    }

    /// Returns (tag→value-array, nextIFDOffset). Values are
    /// captured as `[UInt32]` so the IFD1 offsets/lengths
    /// (typically SHORT or LONG) survive the cast uniformly.
    private static func walkIFD(_ tiff: Data, at offset: Int, endian: Endian)
        -> ([UInt16: [UInt32]], Int?)
    {
        var out: [UInt16: [UInt32]] = [:]
        guard let count = read16(tiff, at: offset, endian).map(Int.init),
              offset + 2 + count * 12 + 4 <= tiff.count else { return (out, nil) }
        let entryBase = offset + 2
        for i in 0 ..< count {
            let e = entryBase + i * 12
            guard let tag    = read16(tiff, at: e,     endian),
                  let typeID = read16(tiff, at: e + 2, endian),
                  let cnt    = read32(tiff, at: e + 4, endian) else { continue }
            let valueField = e + 8
            // We only care about SHORT (3) and LONG (4) for the
            // tags we use here; both fit in the 4-byte value field
            // when count ≤ 1 (or 2 for SHORT). Larger counts point
            // out-of-band, which we don't follow.
            let values = readNumeric(tiff, valueField: valueField,
                                     typeID: Int(typeID), count: Int(cnt),
                                     endian: endian)
            out[tag] = values
        }
        // 4 bytes after the entries: offset to the next IFD (0 = none).
        let nextOff = read32(tiff, at: entryBase + count * 12, endian).map(Int.init) ?? 0
        return (out, nextOff > 0 ? nextOff : nil)
    }

    private static func readNumeric(_ tiff: Data, valueField: Int,
                                    typeID: Int, count: Int,
                                    endian: Endian) -> [UInt32] {
        switch typeID {
        case 3:  // SHORT
            var out: [UInt32] = []
            for k in 0 ..< min(count, 2) {
                if let v = read16(tiff, at: valueField + k * 2, endian) {
                    out.append(UInt32(v))
                }
            }
            return out
        case 4:  // LONG
            if count <= 1, let v = read32(tiff, at: valueField, endian) {
                return [v]
            }
            return []
        default:
            return []
        }
    }

    // MARK: - byte readers

    private enum Endian { case little, big }

    private static func read16(_ data: Data, at offset: Int, _ endian: Endian) -> UInt16? {
        let base = data.startIndex + offset
        guard base + 2 <= data.endIndex else { return nil }
        let a = UInt16(data[base])
        let b = UInt16(data[base + 1])
        return endian == .little ? (b << 8 | a) : (a << 8 | b)
    }

    private static func read32(_ data: Data, at offset: Int, _ endian: Endian) -> UInt32? {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return nil }
        let bytes = (0 ..< 4).map { UInt32(data[base + $0]) }
        switch endian {
        case .little: return (bytes[3] << 24) | (bytes[2] << 16) | (bytes[1] << 8) | bytes[0]
        case .big:    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
        }
    }
}
