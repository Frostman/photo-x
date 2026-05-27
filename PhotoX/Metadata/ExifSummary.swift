import CoreGraphics
import Foundation

struct ExifSummary: Hashable, Sendable, Codable {
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

extension ExifSummary {
    /// Build an `ExifSummary` from one entry of `exiftool -j -G1 -n` output.
    /// Mirrors `ImageIOMetadata.read`'s output shape exactly — the running
    /// app only ever sees ExifSummary, never knows whether it came from
    /// ImageIO or exiftool. Fields absent from the dict become nil silently.
    ///
    /// Assumes `-n` (no print conversions), so numeric fields arrive as
    /// Double/Int rather than pre-formatted strings.
    static func from(exiftoolDict dict: [String: Any]) -> ExifSummary {
        var s = ExifSummary()

        // Camera — Make + Model, with "SONY" → "Sony" pretty-fix.
        let make = string(dict, "EXIF:Make").map(prettyMake)
            ?? string(dict, "IFD0:Make").map(prettyMake)
        let model = string(dict, "EXIF:Model") ?? string(dict, "IFD0:Model")
        s.camera = [make, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty

        // Lens — prefer LensModel (full descriptive name) from either group.
        s.lens = string(dict, "EXIF:LensModel")
            ?? string(dict, "ExifIFD:LensModel")

        // Exposure — exiftool with -n gives raw Doubles.
        if let t = double(dict, "EXIF:ExposureTime") ?? double(dict, "ExifIFD:ExposureTime") {
            s.shutterSpeed = formatShutter(t)
        }
        if let f = double(dict, "EXIF:FNumber") ?? double(dict, "ExifIFD:FNumber") {
            s.aperture = String(format: "f/%.1f", f)
        }
        if let iso = int(dict, "EXIF:ISO") ?? int(dict, "ExifIFD:ISO") {
            s.iso = "ISO \(iso)"
        }
        if let focal = double(dict, "EXIF:FocalLength") ?? double(dict, "ExifIFD:FocalLength") {
            s.focalLength = "\(Int(focal.rounded())) mm"
        }
        if let eb = double(dict, "EXIF:ExposureCompensation")
                 ?? double(dict, "ExifIFD:ExposureCompensation"),
           abs(eb) > 0.001 {
            s.exposureCompensation = String(format: "%+.1f EV", eb)
        }

        // DateTimeOriginal — exiftool default format "yyyy:MM:dd HH:mm:ss".
        if let dateStr = string(dict, "EXIF:DateTimeOriginal")
                      ?? string(dict, "ExifIFD:DateTimeOriginal") {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.timeZone = .current
            s.dateTime = f.date(from: dateStr)
        }

        // Orientation — numeric (1...8). MetadataBatchLoader requests with
        // `-Orientation#`; exiftool emits under the matching group (IFD0
        // for ARW, often top-level for HEIF).
        if let o = int(dict, "IFD0:Orientation")
                ?? int(dict, "EXIF:Orientation")
                ?? int(dict, "Orientation") {
            s.orientation = o
        }

        // ImageSize — Composite:ImageSize is "WxH" (or "W H") across formats.
        if let sizeStr = string(dict, "Composite:ImageSize") {
            let parts = sizeStr.split(whereSeparator: { $0 == "x" || $0 == "X" || $0 == " " })
                              .compactMap { Int($0) }
            if parts.count >= 2 {
                s.pixelWidth = parts[0]
                s.pixelHeight = parts[1]
            }
        }

        return s
    }

    // MARK: dict helpers

    private static func string(_ dict: [String: Any], _ key: String) -> String? {
        guard let v = dict[key] else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func double(_ dict: [String: Any], _ key: String) -> Double? {
        if let d = dict[key] as? Double { return d }
        if let i = dict[key] as? Int    { return Double(i) }
        if let n = dict[key] as? NSNumber { return n.doubleValue }
        if let s = dict[key] as? String, let d = Double(s) { return d }
        return nil
    }

    private static func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let i = dict[key] as? Int { return i }
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String, let i = Int(s) { return i }
        return nil
    }

    // Internal so the in-process TIFF parser (TIFFEXIFParser) and the
    // exiftool-dict path share one set of formatters.
    static func prettyMake(_ make: String) -> String {
        if make == make.uppercased() {
            return make.prefix(1) + make.dropFirst().lowercased()
        }
        return make
    }

    static func formatShutter(_ time: Double) -> String {
        if time <= 0 { return "—" }
        if time >= 0.5 { return String(format: "%.1f s", time) }
        return "1/\(Int((1.0 / time).rounded()))"
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
