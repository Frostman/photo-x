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

    /// Parsed thumbnail + the EXIF-orientation value (1, 3, 6 or 8)
    /// the caller should apply before display. The HEIF stores the
    /// orientation in an `irot` box separate from the JPEG bytes; the
    /// extracted JPEG itself has no EXIF, so without this we'd render
    /// portrait shots sideways.
    struct ExtractedThumbnail: Equatable {
        let jpeg: Data
        let exifOrientation: Int     // 1, 3, 6, or 8
    }

    /// Read the embedded JPEG thumbnail bytes from `url` along with
    /// the HEIF's rotation hint. Returns nil if the file isn't HEIF,
    /// has no JPEG thumbnail item, or the parser can't find one
    /// (defensive — caller falls back to a full-decode path).
    static func extract(from url: URL) throws -> ExtractedThumbnail? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read the first ~256 KB. The `ftyp` + `meta` boxes always sit
        // near the start; for Sony A1 II HIFs the JPEG thumb itself
        // is at ~0x26000 = 152 KB, comfortably inside this window.
        // One read covers parse + extract for the common case.
        let header = try handle.read(upToCount: 256 * 1024) ?? Data()
        guard let location = locateJPEGThumbnail(in: header) else { return nil }
        let orientation = locateOrientation(in: header) ?? 1
        let bytes: Data
        if location.offset + location.length <= header.count {
            bytes = header.subdata(in: location.offset ..< location.offset + location.length)
        } else {
            // Rare: thumb past the first 256 KB. Seek + read directly.
            try handle.seek(toOffset: UInt64(location.offset))
            bytes = (try handle.read(upToCount: location.length)) ?? Data()
        }
        return ExtractedThumbnail(jpeg: bytes, exifOrientation: orientation)
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
