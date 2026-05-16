import CoreGraphics
import Foundation
import ImageIO

struct RAWImageIODecoder: ImageDecoder {
    func decode(url: URL) async throws -> DecodedImage {
        try await Task.detached(priority: .userInitiated) {
            try Self.decodeSync(url: url)
        }.value
    }

    private static func decodeSync(url: URL) throws -> DecodedImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DecodeError.fileNotFound(url)
        }

        let start = CFAbsoluteTimeGetCurrent()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DecodeError.sourceCreationFailed(url)
        }

        // Default RAW pipeline — neutral chromaticities, no auto-brightness override.
        // We pass an empty RAW options dict to force the full RAW path (rather than
        // falling back to the embedded JPEG thumbnail).
        let rawDict: [CFString: Any] = [:]
        let imageOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true,
            kCGImagePropertyRawDictionary: rawDict
        ]

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary) else {
            throw DecodeError.imageCreationFailed(url)
        }

        let decodeMS = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let colorSpaceName = cgImage.colorSpace?.name as String? ?? "unknown"

        return DecodedImage(
            cgImage: cgImage,
            decodeMS: decodeMS,
            colorSpaceName: colorSpaceName
        )
    }
}
