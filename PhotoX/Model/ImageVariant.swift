import Foundation

/// What the canvas is showing for the current entry. `preview` is
/// whichever non-RAW file the entry has (HIF / HEIF / HEIC / JPG /
/// JPEG) — they all decode through the same ImageIO path. `raw` is
/// the ARW, only available when `entry.rawURL != nil`.
enum ImageVariant: String, CaseIterable, Identifiable, Hashable, Sendable {
    case preview
    case raw

    var id: String { rawValue }

    /// User-facing label. Internal-comments / debug logs may say
    /// "preview" — UI text must spell out the formats. The decoding
    /// pill and any "Decoding X…" message reads this.
    var displayName: String {
        switch self {
        case .preview: return "HIF/JPG"
        case .raw:     return "RAW"
        }
    }
}
