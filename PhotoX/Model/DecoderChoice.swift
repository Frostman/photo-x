import Foundation

enum DecoderChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case imageIO
    case libRaw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .imageIO: return "ImageIO"
        case .libRaw: return "LibRaw"
        }
    }
}
