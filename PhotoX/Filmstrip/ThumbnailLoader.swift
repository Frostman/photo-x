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
    /// alongside per-step timings.
    ///
    /// FAST PATH: HEIFs from camera cards carry an embedded JPEG
    /// thumbnail (Sony A1 II: ~160×120, 8 KB) that we can extract
    /// without touching the 50-MP HEVC primary image at all. Reads
    /// ~50–200 KB of the file (header + thumb item), decodes the
    /// JPEG — ~5 ms total vs ~200 ms for a full HEVC decode.
    ///
    /// FALLBACK: if the HEIF parser can't find a JPEG item (e.g.
    /// non-Sony HEICs without an embedded thumb), revert to the old
    /// path: `Data(contentsOf:)` + CGImageSource thumbnail extraction.
    /// Returns `(nil, nil)` only if both paths fail.
    static func loadInstrumented(from url: URL, maxPixelSize: Int = 240)
        -> (image: CGImage?, stats: Stats?)
    {
        // FAST PATH: embedded JPEG thumbnail. Time the whole thing
        // (parse + read + decode + orient + crop) as a single
        // decodeMS measurement since each step is sub-ms.
        let t0 = CFAbsoluteTimeGetCurrent()
        if let extracted = try? HEIFEmbeddedThumbnail.extract(from: url),
           let raw = decode(data: extracted.jpeg, maxPixelSize: maxPixelSize) {
            // Crop FIRST (always in landscape — Sony's embedded thumb
            // is 160×120 with the 3:2 scene letterboxed on top+bottom),
            // THEN rotate. Reversing the order would crop along the
            // wrong axis on portrait shots since rotation transposes
            // width and height.
            let cropped = cropToCameraAspect3by2(raw)
            // The embedded JPEG has NO EXIF orientation tag — Sony
            // stores rotation in the HEIF container's `irot` box.
            // Apply it now or portrait shots render sideways.
            let img = OrientationApplier.apply(orientation: extracted.exifOrientation,
                                               to: cropped)
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            return (img, Stats(
                fileBytes: extracted.jpeg.count,
                readMS:    0,
                decodeMS:  elapsed
            ))
        }
        // FALLBACK: full HEIF decode via ImageIO (the pre-optimisation
        // behavior). Splits read vs decode timing so logs make it
        // obvious which path the file took (huge bytes + big read =
        // fallback path; ~8 KB + 0 ms read = fast path).
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

    /// Center-crop a CGImage to a 3:2 aspect ratio. Used to peel
    /// Sony's letterbox black bands off the 160×120 embedded thumbs
    /// (the actual 3:2 scene is centered inside the 4:3 thumbnail).
    /// No-op when the image is already within 1% of 3:2 — covers the
    /// fallback path's already-correct ImageIO output.
    private static func cropToCameraAspect3by2(_ img: CGImage) -> CGImage {
        let w = img.width
        let h = img.height
        guard w > 0, h > 0 else { return img }
        let actual = Double(w) / Double(h)
        let target = 1.5
        if abs(actual - target) < 0.015 { return img }
        if actual < target {
            // Taller than 3:2 — trim top + bottom.
            let newH = Int((Double(w) / target).rounded())
            let yOffset = (h - newH) / 2
            let rect = CGRect(x: 0, y: yOffset, width: w, height: newH)
            return img.cropping(to: rect) ?? img
        } else {
            // Wider than 3:2 — trim left + right.
            let newW = Int((Double(h) * target).rounded())
            let xOffset = (w - newW) / 2
            let rect = CGRect(x: xOffset, y: 0, width: newW, height: h)
            return img.cropping(to: rect) ?? img
        }
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
