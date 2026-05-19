import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class HEIFDecoder: ImageDecoder {
    /// Optional shared bytes cache. When present, the decoder serves
    /// repeat reads of the same HIF from RAM instead of re-touching the
    /// source media — the win for back-and-forth culling on SD/CFExpress
    /// where every disk seek matters. nil means "always read from disk"
    /// (used by tests + ad-hoc decoder construction).
    let bytesCache: HIFBytesCache?

    init(bytesCache: HIFBytesCache? = nil) {
        self.bytesCache = bytesCache
    }

    func decode(url: URL) async throws -> DecodedImage {
        let cache = self.bytesCache
        return try await Task.detached(priority: .userInitiated) {
            try await Self.run(url: url, bytesCache: cache)
        }.value
    }

    private static func run(url: URL, bytesCache: HIFBytesCache?) async throws -> DecodedImage {
        let data: Data
        if let cache = bytesCache, let cached = await cache.get(url.path) {
            data = cached
        } else {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DecodeError.fileNotFound(url)
            }
            data = try Data(contentsOf: url)
            if let cache = bytesCache {
                await cache.set(data, for: url.path)
            }
        }
        return try decodeFromData(data, sourceURL: url)
    }

    private static func decodeFromData(_ data: Data, sourceURL: URL) throws -> DecodedImage {
        let start = CFAbsoluteTimeGetCurrent()

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       sourceOptions as CFDictionary) else {
            throw DecodeError.sourceCreationFailed(sourceURL)
        }

        let imageOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        guard let rawCGImage = CGImageSourceCreateImageAtIndex(source, 0,
                                                               imageOptions as CFDictionary) else {
            throw DecodeError.imageCreationFailed(sourceURL)
        }

        // Apply EXIF Orientation so portrait shots render upright. The raw
        // CGImage from ImageIO has the sensor-orientation pixel layout; the
        // Orientation tag tells us how to display it.
        let orientation = OrientationApplier.readOrientation(from: source)
        let cgImage = OrientationApplier.apply(orientation: orientation, to: rawCGImage)

        let decodeMS = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let colorSpaceName = cgImage.colorSpace?.name as String? ?? "unknown"

        return DecodedImage(
            cgImage: cgImage,
            decodeMS: decodeMS,
            colorSpaceName: colorSpaceName
        )
    }
}
