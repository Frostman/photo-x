import CoreGraphics
import Foundation
import ImageIO
import IndexingCore

enum ImageIOMetadata {
    static func read(from url: URL) -> ExifSummary {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return ExifSummary()
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux  = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        var s = ExifSummary()

        // Camera
        let make = (tiff[kCGImagePropertyTIFFMake] as? String).map(prettyMake)
        let model = tiff[kCGImagePropertyTIFFModel] as? String
        s.camera = [make, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty

        // Lens (prefer EXIF, fall back to Aux)
        s.lens = (exif[kCGImagePropertyExifLensModel] as? String).nilIfEmpty
            ?? (aux[kCGImagePropertyExifAuxLensModel] as? String).nilIfEmpty

        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            s.shutterSpeed = formatShutter(t)
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double {
            s.aperture = String(format: "f/%.1f", f)
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            ?? (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first.map(Int.init) {
            s.iso = "ISO \(iso)"
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            s.focalLength = "\(Int(focal.rounded())) mm"
        }
        if let eb = exif[kCGImagePropertyExifExposureBiasValue] as? Double, abs(eb) > 0.001 {
            s.exposureCompensation = String(format: "%+.1f EV", eb)
        }
        if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.timeZone = .current
            s.dateTime = f.date(from: dateStr)
        }
        if let orientation = tiff[kCGImagePropertyTIFFOrientation] as? Int {
            s.orientation = orientation
        }
        if let w = props[kCGImagePropertyPixelWidth] as? Int {
            s.pixelWidth = w
        }
        if let h = props[kCGImagePropertyPixelHeight] as? Int {
            s.pixelHeight = h
        }

        return s
    }

    /// "SONY" → "Sony"; otherwise pass through.
    private static func prettyMake(_ make: String) -> String {
        if make == make.uppercased() {
            return make.prefix(1) + make.dropFirst().lowercased()
        }
        return make
    }

    private static func formatShutter(_ time: Double) -> String {
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
