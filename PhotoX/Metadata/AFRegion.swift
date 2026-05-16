import CoreGraphics
import Foundation

struct AFRegion: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case primaryFocus
        case face
        case subject
    }

    let kind: Kind
    /// Rect in IMAGE PIXEL coordinates, origin top-left, y-down.
    let rect: CGRect
    let label: String?

    var id: String {
        "\(kind.rawValue)-\(Int(rect.origin.x))-\(Int(rect.origin.y))-\(Int(rect.width))-\(Int(rect.height))-\(label ?? "")"
    }
}
