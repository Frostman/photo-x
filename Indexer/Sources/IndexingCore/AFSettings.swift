import Foundation

public struct AFSettings: Hashable, Sendable, Codable {
    public var focusMode: String?         // AF-S / AF-C / MF / DMF
    public var afAreaMode: String?        // Wide / Spot / Tracking / Zone …
    public var afTracking: String?        // On / Off
    public var focusDistance: String?     // "∞", "2.3 m"
    public var pointsUsed: Int?
    public var focusFrameSize: String?    // "189 × 192"

    public init(focusMode: String? = nil,
                afAreaMode: String? = nil,
                afTracking: String? = nil,
                focusDistance: String? = nil,
                pointsUsed: Int? = nil,
                focusFrameSize: String? = nil) {
        self.focusMode = focusMode
        self.afAreaMode = afAreaMode
        self.afTracking = afTracking
        self.focusDistance = focusDistance
        self.pointsUsed = pointsUsed
        self.focusFrameSize = focusFrameSize
    }

    public var isEmpty: Bool {
        focusMode == nil && afAreaMode == nil && afTracking == nil
            && focusDistance == nil && pointsUsed == nil && focusFrameSize == nil
    }
}
