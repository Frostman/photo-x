import Foundation

/// On-disk index produced by the Linux indexer (or any other indexer
/// process) and consumed by the PhotoX macOS app. Lives at
/// `<shootFolder>/.photox-index.plist`. The app loads it before its
/// own indexing pipelines run and treats covered stems as cache
/// hits; stems missing from the sidecar fall through to the normal
/// indexing path. The app NEVER writes back to the sidecar — it is
/// owned by the producer.
public struct ShootSidecarIndex: Codable, Sendable, Equatable {
    /// Bump on any breaking schema change (field type changes,
    /// removed fields). Readers see the bump and treat the file as
    /// absent so they rebuild from source.
    public static let currentSchemaVersion = 1

    public var version: Int
    /// When the producer finished writing this index. Surfaced in
    /// the macOS popover as "indexed Xm ago" so the user can tell
    /// at a glance whether to trust the sidecar.
    public var indexedAt: Date
    /// Identity of the producer that wrote the sidecar, e.g.
    /// `v0.1247.0-abc123def`. Shown on hover in the popover.
    public var indexerVersion: String
    /// Per-photo entries keyed by stem (filename without extension),
    /// matching how `IndexerCacheStore` keys its in-memory payload.
    public var entries: [String: IndexEntry]

    public init(version: Int,
                indexedAt: Date,
                indexerVersion: String,
                entries: [String: IndexEntry]) {
        self.version = version
        self.indexedAt = indexedAt
        self.indexerVersion = indexerVersion
        self.entries = entries
    }
}

/// Per-photo entry shape. Mirrors the macOS `IndexerCache.Entry`
/// schema field-for-field, so the macOS app can drop sidecar
/// entries straight into its in-memory payload at shoot open
/// without any per-field translation.
public struct IndexEntry: Codable, Sendable, Equatable {
    public var fingerprint: IndexFingerprint
    /// Standard EXIF summary (Make/Model/Lens/exposure/ISO/etc.)
    /// produced by `TIFFEXIFParser` from the HEIF Exif item bytes
    /// or JPEG APP1 segment. nil when the producer didn't extract
    /// it (e.g. files without an embedded EXIF block — rare).
    public var exif: ExifSummary?
    /// Sony AF regions + settings parsed from MakerNotes via
    /// exiftool. nil when the file has no AF metadata.
    public var afData: ExifToolRunner.AFData?
    /// Burst index for the filmstrip sequence overlay.
    public var sequenceNumber: Int?
    /// Embedded JPEG bytes ready to decode for the filmstrip
    /// thumbnail. ~8 KB on Sony A1 II files. Optional so producers
    /// that miss the fast path can skip thumbnail capture.
    public var thumbnailJPEG: Data?
    /// Orientation actually applied to `thumbnailJPEG` at decode
    /// time (HEIF `irot` mapped to TIFF 1/3/6/8 or JPEG IFD0 tag).
    /// May differ from any EXIF Orientation found in the file's
    /// metadata, so it rides alongside the bytes.
    public var thumbnailOrientation: Int?

    public init(fingerprint: IndexFingerprint,
                exif: ExifSummary? = nil,
                afData: ExifToolRunner.AFData? = nil,
                sequenceNumber: Int? = nil,
                thumbnailJPEG: Data? = nil,
                thumbnailOrientation: Int? = nil) {
        self.fingerprint = fingerprint
        self.exif = exif
        self.afData = afData
        self.sequenceNumber = sequenceNumber
        self.thumbnailJPEG = thumbnailJPEG
        self.thumbnailOrientation = thumbnailOrientation
    }
}

/// Cache key: filesystem state of the underlying photo file. When
/// the macOS app opens a shoot it stat()s each file and matches
/// (size, mtimeNanos) against the sidecar's stored fingerprint —
/// mismatch means the file changed since the sidecar was produced
/// and the cached entry is dropped.
///
/// Equality is **tolerant of up to 1 s of mtime drift** so a
/// sidecar produced on a Linux NAS still matches the file when
/// read via SMB from macOS (Samba dialects round sub-second mtimes
/// in ways that drift from ext4's view by up to ~1 s). Size must
/// match exactly — that's what catches actual file replacement.
public struct IndexFingerprint: Codable, Sendable, Hashable {
    public var size: Int64
    public var mtimeNanos: Int64

    public init(size: Int64, mtimeNanos: Int64) {
        self.size = size
        self.mtimeNanos = mtimeNanos
    }

    /// Maximum mtime drift (in nanoseconds) tolerated by `==`.
    /// Set to 1 s because that's the worst-case offset we've seen
    /// between Linux ext4 mtimes and the same files served via
    /// Samba to a macOS SMB client. Increase if other mount
    /// layers drift further; decrease at your own risk.
    public static let mtimeToleranceNanos: Int64 = 1_000_000_000

    public static func == (lhs: IndexFingerprint, rhs: IndexFingerprint) -> Bool {
        lhs.size == rhs.size
            && abs(lhs.mtimeNanos &- rhs.mtimeNanos) <= mtimeToleranceNanos
    }

    /// Hashes on `size` only so the Hashable<->Equatable contract
    /// holds under the ±1 s mtime tolerance: two values that
    /// compare equal must hash equal, and two values with the same
    /// size *might* compare equal (depending on mtime drift), so
    /// they must land in the same bucket. Mtime is not part of the
    /// hash — equality already does the tolerant comparison.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(size)
    }
}

// MARK: - Reader / writer

public enum SidecarFile {
    /// Hidden filename so it doesn't clutter Finder / Files
    /// listings in the shoot folder.
    public static let filename = ".photox-index.plist"

    public static func url(in shootFolder: URL) -> URL {
        shootFolder.appendingPathComponent(filename)
    }
}

public enum SidecarReader {
    /// Returns nil on missing file, decode error, or version
    /// mismatch — caller treats nil as "no sidecar, fall back to
    /// the normal indexing pipelines".
    public static func load(at shootFolder: URL) -> ShootSidecarIndex? {
        let url = SidecarFile.url(in: shootFolder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? PropertyListDecoder()
                .decode(ShootSidecarIndex.self, from: data) else {
            return nil
        }
        guard payload.version == ShootSidecarIndex.currentSchemaVersion else {
            return nil
        }
        return payload
    }
}

public enum SidecarWriter {
    public enum WriteError: Error {
        case encodeFailed(Error)
        case writeFailed(Error)
    }

    /// Atomic write — `Data.write(.atomic)` uses tmp + rename, so
    /// a concurrent reader either sees the previous version or the
    /// new one but never a half-written file.
    public static func write(_ index: ShootSidecarIndex,
                             to shootFolder: URL) throws {
        let url = SidecarFile.url(in: shootFolder)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(index)
        } catch {
            throw WriteError.encodeFailed(error)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WriteError.writeFailed(error)
        }
    }
}
