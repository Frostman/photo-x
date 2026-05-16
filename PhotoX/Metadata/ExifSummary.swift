import CoreGraphics
import Foundation

struct ExifSummary: Hashable, Sendable {
    var camera: String?
    var lens: String?
    var shutterSpeed: String?
    var aperture: String?
    var iso: String?
    var focalLength: String?
    var exposureCompensation: String?
    var dateTime: Date?
    var orientation: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
}
