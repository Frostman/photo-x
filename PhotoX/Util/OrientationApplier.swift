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
        guard let rotated = context.createCGImage(ciImage, from: ciImage.extent) else {
            return image
        }
        // CIContext.createCGImage returns a CGImage that's "lazy" — the
        // pixels haven't been computed yet, only the recipe. Drawing it
        // (which is what MTKTextureLoader does internally to copy bytes
        // into the GPU upload buffer) triggers a re-rasterization, and
        // that re-rasterization is ~1.5 s on an 8640×5760 portrait shot.
        // Materialise the rotated image into a concrete BGRA8 bitmap so
        // MTKTextureLoader's fast upload path applies on every display.
        return materialise(rotated) ?? rotated
    }

    /// Force-rasterise `image` into a fresh CGContext-backed BGRA8
    /// premul-first bitmap. The output is a "concrete" CGImage whose
    /// pixel bytes are immediately accessible — no lazy CIContext
    /// indirection that MTKTextureLoader would have to chase. Returns
    /// nil if context allocation fails (unusual; the caller should
    /// fall back to the input).
    private static func materialise(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
              ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue
                   | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: bitmap
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
