import Foundation

/// A single photo a user can navigate to. Was "pair" historically
/// (ARW+HIF was the only shape); now it can be any of:
/// - `ARW + HIF` — Sony RAW + HEIF preview (the common case)
/// - `ARW + JPG` — Sony RAW + JPEG preview
/// - `HIF` alone — preview without RAW
/// - `JPG` alone — preview without RAW
///
/// `previewURL` is always present (HIF preferred when both exist);
/// `rawURL` is nil for preview-only entries.
struct PhotoEntry: Identifiable, Hashable, Sendable {
    let rawURL: URL?
    let previewURL: URL
    let stem: String

    var id: String { stem }

    /// Path-based identifier shared by an entry's `.preview` and
    /// `.raw` variants. Used as `DecodeKey.entryID` so the texture
    /// cache + single-flight dedup are unique across shoots — two
    /// shoots that both contain a `DSC04176` would collide on
    /// stem alone, but their `commonPath`s differ. Drops the file
    /// extension so RAW and preview of the same entry hash the
    /// same way.
    var commonPath: String {
        (rawURL ?? previewURL).deletingPathExtension().path
    }

    /// Lightroom-compatible sidecar next to the RAW if we have one,
    /// otherwise next to the preview. Same `<stem>.xmp` either way
    /// because the pair shares a stem.
    var xmpURL: URL {
        (rawURL ?? previewURL).deletingPathExtension()
            .appendingPathExtension("xmp")
    }

    /// True when the preview file is `.jpg` / `.jpeg` rather than
    /// `.hif` / `.heif` / `.heic`. Drives format-honest UI labels
    /// (status pill says "JPEG …" vs "HEIF …").
    var hasJPGPreview: Bool {
        let ext = previewURL.pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }
}

extension PhotoEntry {
    /// Convenience for tests / call sites that already have the
    /// URLs split out and just need the stem derived.
    static func make(rawURL: URL?, previewURL: URL) -> PhotoEntry {
        PhotoEntry(
            rawURL: rawURL,
            previewURL: previewURL,
            stem: previewURL.deletingPathExtension().lastPathComponent
        )
    }
}
