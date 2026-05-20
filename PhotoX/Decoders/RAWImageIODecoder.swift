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

        guard let rawCGImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary) else {
            throw DecodeError.imageCreationFailed(url)
        }

        // Read EXIF Orientation; the renderer rotates via shader (see
        // HEIFDecoder for context). Skipping the CPU rotation here
        // matters more for ARWs than HIFs because the demosaiced raw
        // is even larger than the HEIF's HEVC frame.
        let orientation = OrientationApplier.readOrientation(from: source)

        let decodeMS = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let colorSpaceName = rawCGImage.colorSpace?.name as String? ?? "unknown"

        return DecodedImage(
            cgImage: rawCGImage,
            orientation: orientation,
            decodeMS: decodeMS,
            colorSpaceName: colorSpaceName
        )
    }
}
