import CoreGraphics
import Foundation

struct AFRegion: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case primaryFocus
        case focalPlanePoint    // one of the 9 (or N) AF points on the AF sensor
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

    // Custom Codable: CGRect's synthesized encoding is verbose
    // ({"origin":{"x":…,"y":…},"size":{"width":…,"height":…}}).
    // Flatten to a 4-element array so per-region cache payload
    // stays compact (~30 % size win over the default).
    private enum CodingKeys: String, CodingKey {
        case kind, rect, label
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode([rect.origin.x, rect.origin.y, rect.width, rect.height],
                     forKey: .rect)
        try c.encodeIfPresent(label, forKey: .label)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind  = try c.decode(Kind.self, forKey: .kind)
        let r = try c.decode([CGFloat].self, forKey: .rect)
        guard r.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .rect, in: c,
                debugDescription: "rect expects [x, y, w, h], got \(r.count) elements")
        }
        rect  = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    init(kind: Kind, rect: CGRect, label: String?) {
        self.kind = kind
        self.rect = rect
        self.label = label
    }
}
