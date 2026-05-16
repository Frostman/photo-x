import Foundation

enum ImageVariant: String, CaseIterable, Identifiable, Hashable, Sendable {
    case heif
    case raw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heif: return "HEIF"
        case .raw: return "RAW"
        }
    }
}
