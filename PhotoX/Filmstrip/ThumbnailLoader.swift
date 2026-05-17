import CoreGraphics
import Foundation
import ImageIO

enum ThumbnailLoader {
    /// Extract a small CGImage suitable for the filmstrip. ImageIO uses the
    /// HEIF's embedded preview when available (very fast); falls back to a
    /// downsample of the full image. Returns nil on failure (we just don't
    /// draw a thumbnail).
    static func load(from url: URL, maxPixelSize: Int = 240) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
