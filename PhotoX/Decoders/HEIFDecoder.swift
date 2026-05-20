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
        if let cache = bytesCache {
            if let cached = await cache.get(url.path) {
                #if DEBUG
                let usedMB = await cache.bytesUsed / (1024 * 1024)
                let count  = await cache.count
                Log.decode.notice("HIF bytes HIT: \(url.lastPathComponent, privacy: .public) (\(cached.count, privacy: .public) B, cache \(count, privacy: .public) entries / \(usedMB, privacy: .public) MB)")
                #endif
                data = cached
            } else {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw DecodeError.fileNotFound(url)
                }
                let t0 = CFAbsoluteTimeGetCurrent()
                data = try Data(contentsOf: url)
                let readMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                await cache.set(data, for: url.path)
                #if DEBUG
                let usedMB = await cache.bytesUsed / (1024 * 1024)
                let count  = await cache.count
                Log.decode.notice("HIF bytes MISS: \(url.lastPathComponent, privacy: .public) read \(data.count, privacy: .public) B in \(readMS, format: .fixed(precision: 1)) ms (cache \(count, privacy: .public) entries / \(usedMB, privacy: .public) MB)")
                #endif
            }
        } else {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DecodeError.fileNotFound(url)
            }
            data = try Data(contentsOf: url)
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

        // Read EXIF Orientation but do NOT pre-rotate the pixels — the
        // canvas renderer applies the rotation via shader texture-
        // coordinate transform, which is essentially free on the GPU
        // vs. ~1 s of CPU work to rotate 200 MB for an A1 II portrait.
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
