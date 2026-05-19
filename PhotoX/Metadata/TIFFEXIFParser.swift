import Foundation

/// Minimal TIFF / EXIF reader scoped to the fields `ExifSummary`
/// surfaces in the sidebar (Make / Model / DateTimeOriginal / Orientation /
/// FNumber / ExposureTime / ISO / FocalLength / ExposureCompensation /
/// LensModel / PixelXDimension / PixelYDimension). Walks IFD0, follows
/// the ExifIFD pointer, reads the well-known tag IDs. Doesn't pretend
/// to be a general TIFF reader — only what we feed it via the HEIF Exif
/// item (`HEIFEmbeddedThumbnail.Extracted.exifBytes`).
///
/// Returns nil on malformed input (missing II/MM marker, IFD offset
/// past EOF, etc.). Caller falls back to ImageIO in that case.
enum TIFFEXIFParser {
    /// Parse a TIFF block (II/MM marker + IFD0 + ExifIFD ...) into an
    /// `ExifSummary`. The input is the bytes the HEIF `Exif` item
    /// points at, with the 4-byte big-endian offset prefix already
    /// stripped — i.e. the very first byte should be 0x49 ("I") or
    /// 0x4D ("M").
    static func parse(_ data: Data) -> ExifSummary? {
        guard data.count >= 8 else { return nil }
        let base = data.startIndex
        // Byte-order marker.
        let bom = (data[base], data[base + 1])
        let endian: Endian
        switch bom {
        case (0x49, 0x49): endian = .little   // "II"
        case (0x4D, 0x4D): endian = .big      // "MM"
        default:           return nil
        }
        let reader = Reader(data: data, endian: endian)
        // Magic 42 + IFD0 offset.
        guard reader.read16(at: 2) == 42,
              let ifd0Offset = reader.read32(at: 4).map({ Int($0) }),
              ifd0Offset + 2 <= data.count else { return nil }

        var values: [UInt16: Reader.Value] = [:]
        // Walk IFD0.
        readIFD(reader: reader, at: ifd0Offset, into: &values)
        // Follow ExifIFD pointer (IFD0 tag 0x8769) — many tags live there.
        if let exifPtr = values[0x8769]?.asUInt32().map(Int.init),
           exifPtr + 2 <= data.count {
            readIFD(reader: reader, at: exifPtr, into: &values)
        }

        return assemble(values: values, reader: reader)
    }

    // MARK: - IFD walk

    /// Walk an IFD at `offset`, write entries into `out` keyed by
    /// tag id. Doesn't follow nested-IFD pointers; caller decides
    /// which ones to chase.
    private static func readIFD(reader: Reader,
                                at offset: Int,
                                into out: inout [UInt16: Reader.Value]) {
        guard offset + 2 <= reader.data.count,
              let count = reader.read16(at: offset).map(Int.init) else { return }
        let entryBase = offset + 2
        for i in 0 ..< count {
            let entryOffset = entryBase + i * 12
            guard entryOffset + 12 <= reader.data.count else { return }
            guard let tag    = reader.read16(at: entryOffset),
                  let typeID = reader.read16(at: entryOffset + 2),
                  let cnt    = reader.read32(at: entryOffset + 4) else { return }
            // The next 4 bytes are either the value (if it fits) or a
            // pointer to the value bytes elsewhere in the TIFF stream.
            let valueField = entryOffset + 8
            let value = reader.readValue(typeID: Int(typeID),
                                         count: Int(cnt),
                                         valueFieldOffset: valueField)
            out[tag] = value
        }
    }

    // MARK: - assemble ExifSummary from parsed values

    private static func assemble(values: [UInt16: Reader.Value],
                                 reader: Reader) -> ExifSummary {
        var s = ExifSummary()

        let make  = values[0x010F]?.asASCII().map(ExifSummary.prettyMake)
        let model = values[0x0110]?.asASCII()
        s.camera = [make, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty

        s.lens = values[0xA434]?.asASCII()    // LensModel (ExifIFD)

        if let t = values[0x829A]?.asDouble() {   // ExposureTime (RATIONAL)
            s.shutterSpeed = ExifSummary.formatShutter(t)
        }
        if let f = values[0x829D]?.asDouble() {   // FNumber (RATIONAL)
            s.aperture = String(format: "f/%.1f", f)
        }
        if let iso = values[0x8827]?.asUInt32() {  // ISOSpeedRatings
            s.iso = "ISO \(iso)"
        }
        if let fl = values[0x920A]?.asDouble() {   // FocalLength (RATIONAL)
            s.focalLength = "\(Int(fl.rounded())) mm"
        }
        if let eb = values[0x9204]?.asDouble(),    // ExposureBiasValue (SRATIONAL)
           abs(eb) > 0.001 {
            s.exposureCompensation = String(format: "%+.1f EV", eb)
        }
        if let dateStr = values[0x9003]?.asASCII() {   // DateTimeOriginal
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.timeZone = .current
            s.dateTime = f.date(from: dateStr)
        }
        // EXIF spec defaults orientation to 1 (normal) when the tag is
        // absent. ImageIO follows the same convention, so we mirror it
        // for parity with the rest of the indexer pipeline.
        s.orientation = Int(values[0x0112]?.asUInt32() ?? 1)
        // PixelXDimension / PixelYDimension live in ExifIFD; they're
        // reliable for HEIF where TIFF's ImageWidth/Length are usually
        // unset (the real image is HEVC, not TIFF).
        if let w = values[0xA002]?.asUInt32() { s.pixelWidth  = Int(w) }
        if let h = values[0xA003]?.asUInt32() { s.pixelHeight = Int(h) }

        return s
    }

    // MARK: - byte reader

    enum Endian { case little, big }

    /// Slim TIFF byte reader. All offsets here are relative to the
    /// start of the TIFF block (i.e. the byte index where the II/MM
    /// marker sits).
    struct Reader {
        let data: Data
        let endian: Endian

        func read16(at offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let base = data.startIndex + offset
            let b0 = UInt16(data[base])
            let b1 = UInt16(data[base + 1])
            switch endian {
            case .little: return (b1 << 8) | b0
            case .big:    return (b0 << 8) | b1
            }
        }

        func read32(at offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let base = data.startIndex + offset
            let bs = (0 ..< 4).map { UInt32(data[base + $0]) }
            switch endian {
            case .little: return (bs[3] << 24) | (bs[2] << 16) | (bs[1] << 8) | bs[0]
            case .big:    return (bs[0] << 24) | (bs[1] << 16) | (bs[2] << 8) | bs[3]
            }
        }

        /// Decoded TIFF entry value (boxed because tags arrive in
        /// different shapes — string, integer, rational, etc.).
        enum Value {
            case ascii(String)
            case uint(UInt32)         // SHORT or LONG; we don't need to distinguish for our tags
            case sint(Int32)
            case rational(num: UInt32, den: UInt32)
            case srational(num: Int32, den: Int32)

            func asASCII() -> String? {
                if case .ascii(let s) = self { return s.nilIfEmpty }
                return nil
            }
            func asUInt32() -> UInt32? {
                switch self {
                case .uint(let v):     return v
                case .sint(let v):     return v >= 0 ? UInt32(v) : nil
                case .rational(let n, let d) where d == 1: return n
                default: return nil
                }
            }
            func asDouble() -> Double? {
                switch self {
                case .uint(let v):     return Double(v)
                case .sint(let v):     return Double(v)
                case .rational(let n, let d):
                    return d == 0 ? nil : Double(n) / Double(d)
                case .srational(let n, let d):
                    return d == 0 ? nil : Double(n) / Double(d)
                case .ascii: return nil
                }
            }
        }

        /// Read a tag's value. `valueFieldOffset` points at the 4-byte
        /// slot inside the IFD entry; for values larger than 4 bytes
        /// that slot holds an offset (within the TIFF block) to the
        /// actual bytes. For our scoped tag set we read the FIRST
        /// element when count > 1 (ISO often has count 3 but the first
        /// entry is the meaningful one).
        func readValue(typeID: Int, count: Int, valueFieldOffset: Int) -> Value? {
            guard count > 0 else { return nil }
            // Resolve the bytes location: inline if total ≤ 4, else
            // follow the 4-byte offset stored in the entry.
            let elementSize = typeSize(typeID)
            guard elementSize > 0 else { return nil }
            let totalSize = elementSize * count
            let dataOffset: Int
            if totalSize <= 4 {
                dataOffset = valueFieldOffset
            } else {
                guard let ptr = read32(at: valueFieldOffset).map(Int.init),
                      ptr + totalSize <= data.count else { return nil }
                dataOffset = ptr
            }

            switch typeID {
            case 1, 7:    // BYTE / UNDEFINED
                guard dataOffset < data.count else { return nil }
                return .uint(UInt32(data[data.startIndex + dataOffset]))
            case 2:       // ASCII (null-terminated string)
                let bytes = data[data.startIndex + dataOffset
                                 ..< data.startIndex + dataOffset + count]
                // Strip trailing null(s).
                let trimmed = bytes.prefix { $0 != 0 }
                return .ascii(String(decoding: trimmed, as: UTF8.self))
            case 3:       // SHORT
                return read16(at: dataOffset).map { .uint(UInt32($0)) }
            case 4:       // LONG
                return read32(at: dataOffset).map { .uint($0) }
            case 5:       // RATIONAL = two LONGs
                guard let n = read32(at: dataOffset),
                      let d = read32(at: dataOffset + 4) else { return nil }
                return .rational(num: n, den: d)
            case 9:       // SLONG
                return read32(at: dataOffset).map { .sint(Int32(bitPattern: $0)) }
            case 10:      // SRATIONAL = two SLONGs
                guard let n = read32(at: dataOffset),
                      let d = read32(at: dataOffset + 4) else { return nil }
                return .srational(num: Int32(bitPattern: n),
                                  den: Int32(bitPattern: d))
            default:
                return nil
            }
        }

        private func typeSize(_ typeID: Int) -> Int {
            switch typeID {
            case 1, 2, 7:  return 1     // BYTE, ASCII, UNDEFINED
            case 3:        return 2     // SHORT
            case 4, 9:     return 4     // LONG, SLONG
            case 5, 10:    return 8     // RATIONAL, SRATIONAL
            default:       return 0
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
