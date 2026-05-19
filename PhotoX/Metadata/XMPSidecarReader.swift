import CoreGraphics
import Foundation
import ImageIO

enum XMPSidecarReader {
    /// Reads the XMP sidecar for a pair (looked up as `<stem>.xmp` next to the
    /// ARW per Lightroom convention). Returns `.empty` if the file is missing,
    /// unreadable, or malformed. Read-only — never mutates anything.
    static func read(for pair: PhotoPair) -> XMPSidecar {
        let url = pair.rawURL.deletingPathExtension().appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return .empty
        }
        guard let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else {
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
