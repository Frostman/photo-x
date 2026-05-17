import CoreGraphics
import CoreImage
import ImageIO

/// Reads the EXIF Orientation tag from a CGImageSource and (if not Up)
/// re-renders the supplied CGImage in display orientation via Core Image.
/// Returns the input unchanged when orientation is 1 (Up) or invalid.
enum OrientationApplier {
    /// EXIF Orientation values (1–8 per the TIFF spec).
    static func readOrientation(from source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return 1
        }
        if let o = properties[kCGImagePropertyOrientation] as? Int { return o }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let o = tiff[kCGImagePropertyTIFFOrientation] as? Int {
            return o
        }
        return 1
    }

    static func apply(orientation: Int, to image: CGImage) -> CGImage {
        guard orientation > 1, orientation <= 8,
              let exifOrientation = CGImagePropertyOrientation(rawValue: UInt32(orientation)) else {
            return image
        }
        let ciImage = CIImage(cgImage: image).oriented(exifOrientation)
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent) ?? image
    }
}
