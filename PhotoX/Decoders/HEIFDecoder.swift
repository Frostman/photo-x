import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct HEIFDecoder: ImageDecoder {
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

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            throw DecodeError.sourceCreationFailed(url)
        }

        let imageOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
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
