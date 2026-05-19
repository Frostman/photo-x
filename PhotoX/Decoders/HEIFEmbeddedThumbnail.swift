import Foundation

/// Minimal ISOBMFF box parser scoped to one job: locate the embedded
/// JPEG thumbnail item in a HEIF file and return its byte range.
///
/// Sony A1 II HIFs (and most camera HEIFs) carry a tiny ~160×120 JPEG
/// alongside the primary HEVC image. Decoding that JPEG is ~5 ms;
/// decoding the primary 50-MP HEVC for a thumbnail via ImageIO is
/// ~200 ms. For the indexing thumbnail pipeline this is a 40× speedup.
///
/// Doesn't pretend to be a general HEIF reader — only the boxes we
/// need (`ftyp`, `meta` → `iinf` + `iloc`). Box layout reference:
/// ISO/IEC 14496-12 (ISOBMFF base) + ISO/IEC 23008-12 (HEIF).
enum HEIFEmbeddedThumbnail {
    /// Byte range of an item's data inside the file.
    struct ItemLocation: Equatable {
        let offset: Int
        let length: Int
    }

    /// Parsed thumbnail + EXIF block + rotation hint. The HEIF stores
    /// the orientation in an `irot` box separate from the JPEG bytes;
    /// the extracted JPEG itself has no EXIF, so without this we'd
    /// render portrait shots sideways. The `exifBytes` blob is the
    /// TIFF data the HEIF's `Exif` item points at (with the 4-byte
    /// offset prefix stripped) — feed it to `TIFFEXIFParser.parse`
    /// to populate the sidebar without ever touching exiftool.
    struct ExtractedThumbnail: Equatable {
        let jpeg: Data
        let exifOrientation: Int     // 1, 3, 6, or 8
        let exifBytes: Data?         // TIFF block, ready for TIFFEXIFParser
    }

    /// Read the embedded JPEG thumbnail bytes + Exif TIFF block from
    /// `url` along with the HEIF's rotation hint. Returns nil if the
    /// file isn't HEIF, has no JPEG thumbnail item, or the parser
    /// can't find one (defensive — caller falls back to a
    /// full-decode path). `exifBytes` is independently nullable: a
    /// HEIF may have a thumbnail item but no Exif item (rare).
    static func extract(from url: URL) throws -> ExtractedThumbnail? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read the first ~256 KB. The `ftyp` + `meta` boxes always sit
        // near the start; for Sony A1 II HIFs the JPEG thumb itself
        // is at ~0x26000 = 152 KB and the Exif item is in the first
        // few KB. One read covers parse + both extracts.
        let header = try handle.read(upToCount: 256 * 1024) ?? Data()
        guard let jpegLoc = locateJPEGThumbnail(in: header) else { return nil }
        let orientation = locateOrientation(in: header) ?? 1
        let exifLoc = locateExifItem(in: header)

        let jpegBytes: Data
        if jpegLoc.offset + jpegLoc.length <= header.count {
            jpegBytes = header.subdata(in: jpegLoc.offset ..< jpegLoc.offset + jpegLoc.length)
        } else {
            try handle.seek(toOffset: UInt64(jpegLoc.offset))
            jpegBytes = (try handle.read(upToCount: jpegLoc.length)) ?? Data()
        }

        let exifBytes: Data? = readExifBytes(from: header, handle: handle, location: exifLoc)

        return ExtractedThumbnail(jpeg: jpegBytes,
                                  exifOrientation: orientation,
                                  exifBytes: exifBytes)
    }

    /// HEIF Exif items begin with a 4-byte big-endian offset that
    /// points to the TIFF header WITHIN the item data, measured from
    /// the byte just after the offset field itself. Sony A1 II HIFs
    /// use offset=6, with an "Exif\0\0" magic prefix in those 6 bytes
    /// before the TIFF block. Some files use offset=0 (TIFF starts
    /// immediately after the 4-byte field, no Exif magic).
    ///
    /// Either way, the byte index where the parser should start is
    /// `4 + offset` from the start of the item data. Returns nil when
    /// no Exif item exists or the resolved start lands past EOF.
    private static func readExifBytes(from header: Data,
                                      handle: FileHandle,
                                      location: ItemLocation?) -> Data? {
        guard let loc = location, loc.length >= 4 else { return nil }
        let raw: Data
        if loc.offset + loc.length <= header.count {
            raw = header.subdata(in: loc.offset ..< loc.offset + loc.length)
        } else {
            // Rare: Exif item past first 256 KB.
            try? handle.seek(toOffset: UInt64(loc.offset))
            raw = (try? handle.read(upToCount: loc.length)) ?? Data()
        }
        guard raw.count >= 4 else { return nil }
        // 4-byte big-endian offset → byte index of the TIFF marker
        // within `raw`, counting from byte 4.
        let base = raw.startIndex
        let tiffStart = 4 + Int(
            (UInt32(raw[base]) << 24)
          | (UInt32(raw[base + 1]) << 16)
          | (UInt32(raw[base + 2]) << 8)
          |  UInt32(raw[base + 3])
        )
        guard tiffStart < raw.count else { return nil }
        return raw.subdata(in: tiffStart ..< raw.count)
    }

    /// Walk `meta` to locate the item whose item_type is "Exif"
    /// (case-sensitive per HEIF spec) and return its byte range via
    /// the same `iloc` table the JPEG locator uses. Returns nil if
    /// either the `iinf` lookup or the `iloc` cross-reference miss.
    static func locateExifItem(in data: Data) -> ItemLocation? {
        var cursor = BoxCursor(data: data, base: 0, end: data.count)
        while let box = cursor.next() {
            if box.type == "meta" {
                return parseMetaFindItem(in: data, box: box, type: "Exif")
            }
        }
        return nil
    }

    /// Generalised version of `parseMeta` — takes a target item_type
    /// instead of hard-coding "jpeg". Looks up the matching item_id
    /// in `iinf` and resolves it via `iloc`.
    private static func parseMetaFindItem(in data: Data, box: Box,
                                          type itemType: String) -> ItemLocation? {
        guard box.body.count >= 4 else { return nil }
        var cursor = BoxCursor(data: data,
                               base: box.bodyOffset + 4,
                               end: box.bodyOffset + box.body.count)
        var wantedID: UInt32?
        var locations: [UInt32: ItemLocation] = [:]
        while let child = cursor.next() {
            switch child.type {
            case "iinf":
                if let id = parseIINF_findItemID(in: data, box: child, type: itemType) {
                    wantedID = id
                }
            case "iloc":
                locations = parseILOC(in: data, box: child)
            default:
                break
            }
            if wantedID != nil && !locations.isEmpty { break }
        }
        guard let id = wantedID, let loc = locations[id] else { return nil }
        return loc
    }

    /// Like `parseIINF_findJPEGItemID` but takes any target type
    /// ("jpeg", "Exif", "hvc1", …). The existing JPEG locator is now
    /// a thin specialisation of this.
    private static func parseIINF_findItemID(in data: Data, box: Box,
                                              type itemType: String) -> UInt32? {
        guard box.body.count >= 6 else { return nil }
        let version = box.body[box.body.startIndex]
        let countBytes = version >= 1 ? 4 : 2
        let headerLen = 4 + countBytes
        guard box.body.count >= headerLen else { return nil }
        var cursor = BoxCursor(data: data,
                               base: box.bodyOffset + headerLen,
                               end: box.bodyOffset + box.body.count)
        while let child = cursor.next() {
            if child.type != "infe" { continue }
            let body = child.body
            guard body.count >= 12 else { continue }
            let infeVersion = body[body.startIndex]
            let idSize = (infeVersion == 2) ? 2 : 4
            let typeOffset = 4 + idSize + 2
            guard body.count >= typeOffset + 4 else { continue }
            let foundType = asciiString(body, offset: typeOffset, length: 4)
            if foundType == itemType {
                if idSize == 2 {
                    return UInt32(readU16(body, at: 4))
                } else {
                    return readU32(body, at: 4)
                }
            }
        }
        return nil
    }

    /// Pure box-walk. Looks for the top-level `meta` box and asks the
    /// meta parser to find the JPEG thumbnail item's location.
    /// Returns nil if no `meta` or no JPEG item exists.
    static func locateJPEGThumbnail(in data: Data) -> ItemLocation? {
        var cursor = BoxCursor(data: data, base: 0, end: data.count)
        while let box = cursor.next() {
            if box.type == "meta" {
                return parseMeta(in: data, box: box)
            }
        }
        return nil
    }

    /// Pure box-walk for HEIF rotation. Looks for the first `irot`
    /// box anywhere under `meta` → `iprp` → `ipco`. Maps the
    /// 0/1/2/3 (90° counter-clockwise steps) value to the equivalent
    /// EXIF orientation (1 / 8 / 3 / 6). Returns nil if no irot
    /// found, in which case the caller treats it as "1" (no rotation).
    ///
    /// Note: we don't disambiguate via `ipma` which property is
    /// associated with WHICH item — for camera HEIFs the same
    /// rotation applies to all items (primary HEVC + embedded JPEG
    /// thumb were shot at the same orientation). If a file ever has
    /// multiple distinct `irot`s we use the first.
    static func locateOrientation(in data: Data) -> Int? {
        var cursor = BoxCursor(data: data, base: 0, end: data.count)
        while let top = cursor.next() {
            guard top.type == "meta" else { continue }
            // meta is a FullBox: skip 4-byte version+flags header.
            guard top.body.count >= 4 else { return nil }
            var metaCursor = BoxCursor(data: data,
                                       base: top.bodyOffset + 4,
                                       end: top.bodyOffset + top.body.count)
            while let child = metaCursor.next() {
                guard child.type == "iprp" else { continue }
                // iprp contains an ipco (ItemPropertyContainer); ipco
                // is a sequence of property boxes.
                var iprpCursor = BoxCursor(data: data,
                                           base: child.bodyOffset,
                                           end: child.bodyOffset + child.body.count)
                while let property = iprpCursor.next() {
                    guard property.type == "ipco" else { continue }
                    var ipcoCursor = BoxCursor(data: data,
                                               base: property.bodyOffset,
                                               end: property.bodyOffset + property.body.count)
                    while let prop = ipcoCursor.next() {
                        if prop.type == "irot", let firstByte = prop.body.first {
                            // Per ISO/IEC 23008-12 § 6.5.10: lower 2
                            // bits = angle in 90° CCW steps.
                            switch firstByte & 0x03 {
                            case 0: return 1     // no rotation
                            case 1: return 8     // 90° CCW = 270° CW = EXIF 8
                            case 2: return 3     // 180° = EXIF 3
                            case 3: return 6     // 270° CCW = 90° CW = EXIF 6
                            default: return 1
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - meta parsing

    /// `meta` is a FullBox: 1 byte version + 3 byte flags, then nested
    /// boxes. We need `iinf` (find the JPEG item's id) and `iloc`
    /// (resolve that id to a byte range). Order isn't fixed in the
    /// spec — collect both, then cross-reference.
    private static func parseMeta(in data: Data, box: Box) -> ItemLocation? {
        // Skip the 4-byte FullBox header (version + flags).
        guard box.body.count >= 4 else { return nil }
        let inner = box.body.advanced(by: 4)
        var cursor = BoxCursor(data: data,
                               base: box.bodyOffset + 4,
                               end: box.bodyOffset + box.body.count)
        var jpegItemID: UInt32?
        var locations: [UInt32: ItemLocation] = [:]
        _ = inner   // silence unused
        while let child = cursor.next() {
            switch child.type {
            case "iinf":
                if let id = parseIINF_findJPEGItemID(in: data, box: child) {
                    jpegItemID = id
                }
            case "iloc":
                locations = parseILOC(in: data, box: child)
            default:
                break
            }
            // Stop walking once both signals are gathered. Order in
            // the file isn't guaranteed — if `iloc` was first, keep
            // walking until `iinf` is seen too.
            if jpegItemID != nil && !locations.isEmpty { break }
        }
        guard let id = jpegItemID, let loc = locations[id] else { return nil }
        return loc
    }

    /// `iinf` (Item Info Box) — FullBox + entry_count + N × `infe`.
    /// Returns the item_id of the first entry with item_type == "jpeg".
    ///
    /// Layout (v0):  count = 2 bytes
    /// Layout (v1+): count = 4 bytes
    /// Each `infe` box (v2+): version+flags(4) + item_id(2) +
    ///   protection_index(2) + item_type(4) + item_name(\0-terminated)
    ///   + (optional content_type, content_encoding).
    private static func parseIINF_findJPEGItemID(in data: Data, box: Box) -> UInt32? {
        guard box.body.count >= 6 else { return nil }
        let version = box.body[box.body.startIndex]
        let countBytes = version >= 1 ? 4 : 2
        let headerLen = 4 + countBytes
        guard box.body.count >= headerLen else { return nil }

        var cursor = BoxCursor(data: data,
                               base: box.bodyOffset + headerLen,
                               end: box.bodyOffset + box.body.count)
        while let child = cursor.next() {
            if child.type != "infe" { continue }
            // infe v2/v3: skip version(1) + flags(3) + item_id(2) +
            // protection_index(2) → read item_type(4).
            let body = child.body
            guard body.count >= 12 else { continue }
            let infeVersion = body[body.startIndex]
            let idSize = (infeVersion == 2) ? 2 : 4    // v3 uses 4-byte id
            let typeOffset = 4 + idSize + 2
            guard body.count >= typeOffset + 4 else { continue }
            let itemType = asciiString(body, offset: typeOffset, length: 4)
            if itemType == "jpeg" {
                if idSize == 2 {
                    let id = readU16(body, at: 4)
                    return UInt32(id)
                } else {
                    return readU32(body, at: 4)
                }
            }
        }
        return nil
    }

    /// `iloc` (Item Location Box). FullBox + a 16-bit field that
    /// describes how many bytes each location field uses (nibbles for
    /// offset/length/base/index sizes), then per-item entries.
    /// Returns a map of item_id → first extent's (offset, length).
    ///
    /// Layout (v0/1):
    ///   version+flags(4) + sizes(2) + item_count(2)
    ///   for each item:
    ///     item_id(2) + [v1: 2-byte reserved+construction_method]
    ///                + data_reference_index(2)
    ///                + base_offset(base_size)
    ///                + extent_count(2)
    ///                + extents...
    /// Layout (v2):
    ///   version+flags(4) + sizes(2) + item_count(4)
    ///   for each item:
    ///     item_id(4) + 2-byte reserved+construction_method
    ///                + data_reference_index(2)
    ///                + base_offset(base_size)
    ///                + extent_count(2) + extents...
    ///
    /// Each extent: [v1+ extent_index(index_size)] + extent_offset(offset_size)
    /// + extent_length(length_size).
    private static func parseILOC(in data: Data, box: Box) -> [UInt32: ItemLocation] {
        var result: [UInt32: ItemLocation] = [:]
        let body = box.body
        guard body.count >= 8 else { return result }
        let version = body[body.startIndex]

        // Sizes nibble pair (4 bits each).
        let sizeByte0 = body[body.startIndex + 4]
        let sizeByte1 = body[body.startIndex + 5]
        let offsetSize = Int((sizeByte0 >> 4) & 0x0F)
        let lengthSize = Int(sizeByte0 & 0x0F)
        let baseOffsetSize = Int((sizeByte1 >> 4) & 0x0F)
        // index_size only present in v1/v2; for v0 the upper nibble is reserved.
        let indexSize = (version >= 1) ? Int(sizeByte1 & 0x0F) : 0

        let itemCountSize = (version < 2) ? 2 : 4
        guard body.count >= 6 + itemCountSize else { return result }
        let itemCount: Int = (version < 2)
            ? Int(readU16(body, at: 6))
            : Int(readU32(body, at: 6))

        var p = 6 + itemCountSize
        let itemIDSize = (version < 2) ? 2 : 4

        for _ in 0 ..< itemCount {
            // item_id
            guard p + itemIDSize <= body.count else { return result }
            let itemID: UInt32 = (itemIDSize == 2)
                ? UInt32(readU16(body, at: p))
                : readU32(body, at: p)
            p += itemIDSize

            // v1/v2: 16 bits of reserved + construction_method
            if version >= 1 {
                guard p + 2 <= body.count else { return result }
                p += 2
            }

            // data_reference_index (2)
            guard p + 2 <= body.count else { return result }
            p += 2

            // base_offset (base_offset_size bytes)
            guard p + baseOffsetSize <= body.count else { return result }
            let baseOffset = readVarUInt(body, at: p, size: baseOffsetSize)
            p += baseOffsetSize

            // extent_count (2)
            guard p + 2 <= body.count else { return result }
            let extentCount = Int(readU16(body, at: p))
            p += 2

            // Walk extents; remember the first one.
            var first: ItemLocation?
            for i in 0 ..< extentCount {
                if version >= 1 && indexSize > 0 {
                    guard p + indexSize <= body.count else { return result }
                    p += indexSize
                }
                guard p + offsetSize + lengthSize <= body.count else { return result }
                let extentOffset = readVarUInt(body, at: p, size: offsetSize)
                p += offsetSize
                let extentLength = readVarUInt(body, at: p, size: lengthSize)
                p += lengthSize
                if i == 0 {
                    first = ItemLocation(
                        offset: Int(baseOffset + extentOffset),
                        length: Int(extentLength)
                    )
                }
            }
            if let f = first {
                result[itemID] = f
            }
        }
        return result
    }

    // MARK: - low-level box walker

    private struct Box {
        let type: String           // 4-char ASCII
        /// Absolute offset of the box's BODY (after size+type header)
        /// within the parser's source data.
        let bodyOffset: Int
        /// Slice of source data covering just this box's body.
        let body: Data
    }

    private struct BoxCursor {
        let data: Data
        var pos: Int        // absolute offset into data
        let end: Int        // exclusive

        init(data: Data, base: Int, end: Int) {
            self.data = data
            self.pos = base
            self.end = end
        }

        mutating func next() -> Box? {
            guard pos + 8 <= end else { return nil }
            let size32 = readU32(data, at: pos)
            let type = asciiString(data, offset: pos + 4, length: 4)
            var headerLen = 8
            var totalSize: Int
            if size32 == 1 {
                // Extended 64-bit size.
                guard pos + 16 <= end else { return nil }
                totalSize = Int(readU64(data, at: pos + 8))
                headerLen = 16
            } else if size32 == 0 {
                // size == 0 means "to end of file"; we treat as the rest of our window.
                totalSize = end - pos
            } else {
                totalSize = Int(size32)
            }
            guard totalSize >= headerLen, pos + totalSize <= end else { return nil }
            let bodyStart = pos + headerLen
            let bodyLen = totalSize - headerLen
            let body = data.subdata(in: bodyStart ..< bodyStart + bodyLen)
            pos += totalSize
            return Box(type: type, bodyOffset: bodyStart, body: body)
        }
    }

    // MARK: - byte helpers

    static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
             | (UInt32(data[base + 1]) << 16)
             | (UInt32(data[base + 2]) << 8)
             |  UInt32(data[base + 3])
    }

    static func readU64(_ data: Data, at offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var v: UInt64 = 0
        for i in 0 ..< 8 {
            v = (v << 8) | UInt64(data[base + i])
        }
        return v
    }

    /// Read a big-endian unsigned int of variable byte width (0...8).
    /// Used for `iloc`'s offset / length / base_offset fields, whose
    /// widths are declared in the sizes nibble pair.
    static func readVarUInt(_ data: Data, at offset: Int, size: Int) -> UInt64 {
        let base = data.startIndex + offset
        var v: UInt64 = 0
        for i in 0 ..< size {
            v = (v << 8) | UInt64(data[base + i])
        }
        return v
    }

    static func asciiString(_ data: Data, offset: Int, length: Int) -> String {
        let base = data.startIndex + offset
        let bytes = data[base ..< base + length]
        return String(decoding: bytes, as: UTF8.self)
    }
}
