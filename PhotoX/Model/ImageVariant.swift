import Foundation

/// What the canvas is showing for the current entry. `preview` is
/// whichever non-RAW file the entry has (HIF / HEIF / HEIC / JPG /
/// JPEG) — they all decode through the same ImageIO path. `raw` is
/// the ARW, only available when `entry.rawURL != nil`.
enum ImageVariant: String, CaseIterable, Identifiable, Hashable, Sendable {
    case preview
    case raw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preview: return "Preview"
        case .raw:     return "RAW"
        }
    }
}
