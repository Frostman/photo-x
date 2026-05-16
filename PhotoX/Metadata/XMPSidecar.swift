import Foundation

/// What's been recorded in a `<stem>.xmp` sidecar next to the ARW. Read-only
/// for now (writing lands in a later phase). Values follow the Adobe XMP
/// conventions used by Lightroom and PhotoCuller.
struct XMPSidecar: Hashable, Sendable {
    /// `xmp:Rating`. nil = no rating tag in the sidecar; -1 = rejected;
    /// 0 = explicitly cleared; 1...5 = star count.
    var rating: Int?
    /// `xmp:Label`. Typically "Red" / "Yellow" / "Green" / "Blue" / "Purple"
    /// (Lightroom defaults) but can be any string.
    var label: String?

    var isReject: Bool { rating == -1 }

    /// Star count to render, or nil if there's no positive rating.
    var starCount: Int? {
        guard let r = rating, r > 0 else { return nil }
        return min(r, 5)
    }

    /// True if there's anything worth displaying.
    var hasDecision: Bool {
        rating != nil || (label?.isEmpty == false)
    }

    static let empty = XMPSidecar()
}
