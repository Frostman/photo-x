import CoreGraphics
import Foundation
import ImageIO

enum ThumbnailLoader {
    /// File-read vs decode timing for one thumbnail. Used by the indexer
    /// to log per-batch aggregates so we can see whether the bottleneck
    /// is disk IO (cold SD card, network mount) or CPU (HEIF decode of
    /// files without an embedded thumb).
    struct Stats: Sendable, Hashable {
        var fileBytes: Int = 0
        var readMS:    Double = 0    // disk → memory
        var decodeMS:  Double = 0    // CGImageSource extract + scale
    }

    /// Extract a small CGImage suitable for the filmstrip and return it
    /// alongside per-step timings. Splits the work into:
    ///   1. `Data(contentsOf:)` — disk read (or page-cache hit)
    ///   2. `CGImageSourceCreateWithData` + `…ThumbnailAtIndex` — decode
    /// so we can tell which side is hot. Returns `(nil, nil)` if either
    /// step fails (caller treats absence as "thumbnail not available").
    static func loadInstrumented(from url: URL, maxPixelSize: Int = 240)
        -> (image: CGImage?, stats: Stats?)
    {
        let t0 = CFAbsoluteTimeGetCurrent()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return (nil, nil)
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let img = decode(data: data, maxPixelSize: maxPixelSize)
        let t2 = CFAbsoluteTimeGetCurrent()
        return (img, Stats(
            fileBytes: data.count,
            readMS:    (t1 - t0) * 1000.0,
            decodeMS:  (t2 - t1) * 1000.0
        ))
    }

    /// Convenience: throw away the stats. Kept for any caller that just
    /// wants the image (tests, debugging) — the indexer uses the
    /// instrumented variant directly so it can roll up stats per batch.
    static func load(from url: URL, maxPixelSize: Int = 240) -> CGImage? {
        loadInstrumented(from: url, maxPixelSize: maxPixelSize).image
    }

    private static func decode(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        // IMPORTANT: `…IfAbsent`, NOT `…Always`. `Always` forces ImageIO to
        // skip the HEIF's embedded thumbnail and downscale from the full
        // image — a 50-MP HEVC decode per file (~600 ms on Sony A1 II).
        // `IfAbsent` uses the embedded thumb when present (camera HEIFs
        // always embed one) and only full-decodes when missing.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
