import Foundation

/// A folder of `PhotoEntry`s being culled together. An entry can be
/// an `ARW + HIF` pair, an `ARW + JPG` pair, or a standalone preview
/// (HIF / JPG) with no RAW.
///
/// `previewFingerprints` and `xmpStems` are populated by
/// `ShootScanner.scan(folder:)` from the same directory listing that
/// built `entries`, so consumers don't need to re-stat any file on
/// the shoot-open hot path. Both default to empty for legacy call
/// sites (tests, file-drop) that construct a `Shoot` without going
/// through the scanner.
public struct Shoot: Identifiable, Hashable, Sendable {
    public let folderURL: URL
    public let entries: [PhotoEntry]
    /// (size, mtime) per entry stem, harvested from the
    /// `previewURL`'s cached resource values during the scan.
    /// Sole source of fingerprint info on shoot open — the macOS
    /// app feeds these directly into `IndexerCache.entry(for:fingerprint:)`
    /// instead of stat-ing each file separately.
    public let previewFingerprints: [String: IndexFingerprint]
    /// Stems whose folder listing contained a sibling `<stem>.xmp`.
    /// Sole source of XMP existence info on shoot open — the macOS
    /// app's XMP read pipeline skips any stem not in this set
    /// instead of calling `FileManager.fileExists` per entry.
    public let xmpStems: Set<String>

    public init(folderURL: URL,
                entries: [PhotoEntry],
                previewFingerprints: [String: IndexFingerprint] = [:],
                xmpStems: Set<String> = []) {
        self.folderURL = folderURL
        self.entries = entries
        self.previewFingerprints = previewFingerprints
        self.xmpStems = xmpStems
    }

    public var id: URL { folderURL }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public func index(of entry: PhotoEntry) -> Int? {
        entries.firstIndex { $0.id == entry.id }
    }
}
