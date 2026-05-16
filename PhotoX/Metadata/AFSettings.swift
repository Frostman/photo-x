import Foundation

struct AFSettings: Hashable, Sendable {
    var focusMode: String?         // AF-S / AF-C / MF / DMF
    var afAreaMode: String?        // Wide / Spot / Tracking / Zone …
    var afTracking: String?        // On / Off
    var focusDistance: String?     // "∞", "2.3 m"
    var pointsUsed: Int?
    var focusFrameSize: String?    // "189 × 192"

    var isEmpty: Bool {
        focusMode == nil && afAreaMode == nil && afTracking == nil
            && focusDistance == nil && pointsUsed == nil && focusFrameSize == nil
    }
}
