import CoreGraphics
import IndexingCore
import Foundation
import ImageIO

enum XMPSidecarReader {
    /// Reads the XMP sidecar for an entry (looked up as `<stem>.xmp`
    /// next to the RAW when present, else next to the preview file —
    /// matches Lightroom's convention). Returns `nil` when the file
    /// is missing (the caller distinguishes "no file on disk" from
    /// "file present but blank" — the latter returns
    /// `XMPSidecar.empty`). Unreadable / malformed XMPs that DO
    /// exist on disk return `.empty` so the indexer can still flag
    /// the stem as "has-XMP" for the pill badge. Read-only.
    static func read(for entry: PhotoEntry) -> XMPSidecar? {
        let url = entry.xmpURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else {
            #if DEBUG
            Log.app.notice("XMPSidecarReader: failed to parse \(url.lastPathComponent, privacy: .public)")
            #endif
            return .empty
        }

        var sidecar = XMPSidecar()
        if let s = string(metadata, "xmp:Rating"), let i = Int(s) {
            sidecar.rating = i
        }
        if let s = string(metadata, "xmp:Label"), !s.isEmpty {
            sidecar.label = s
        }
        return sidecar
    }

    private static func string(_ metadata: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else {
            return nil
        }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
