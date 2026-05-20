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

    /// Extract a small CGImage suitable for the filmstrip + the standard
    /// EXIF that sits alongside it in the source preview file, along
    /// with per-step timings. One file read powers both outputs.
    ///
    /// FAST PATH (HIF / HEIF / HEIC): HEIFs from camera cards carry an
    /// embedded JPEG thumbnail (Sony A1 II: ~160×120, 8 KB) AND an
    /// Exif item (TIFF block with Make/Model/Lens/exposure/etc.). Both
    /// live in the first ~256 KB of the file. Parsing those bytes
    /// in-process (~5 ms total) gives us thumb + ExifSummary without
    /// any subprocess spawn or ImageIO call.
    ///
    /// FAST PATH (JPG / JPEG): camera JPGs carry the same kind of
    /// IFD1 thumbnail inside their APP1 EXIF segment, with the same
    /// 160×120 sizing. Same in-process treatment via
    /// `JPEGEmbeddedThumbnail` — no ImageIO call until the canvas
    /// wants the full image.
    ///
    /// FALLBACK: if neither parser can produce a thumbnail (web-edited
    /// JPGs without IFD1, non-Sony HEICs), revert to ImageIO. No
    /// ExifSummary in that case — caller (the indexer) leaves
    /// `entryExif` empty for that file and the sidebar shows nothing
    /// until the advanced-EXIF pipeline catches up. Returns
    /// `(nil, nil, nil)` only if every path fails.
    static func loadInstrumented(from url: URL, maxPixelSize: Int = 240)
        -> (image: CGImage?, exif: ExifSummary?, stats: Stats?)
    {
        let t0 = CFAbsoluteTimeGetCurrent()
        let ext = url.pathExtension.lowercased()
        // FAST PATH: embedded thumbnail + EXIF in one header read.
        // Dispatch on extension — the parsers diverge in container
        // shape (ISOBMFF box tree vs JPG marker chain) even though
        // both extract a TIFF block + a tiny embedded JPG.
        if let extracted = extractEmbedded(from: url, ext: ext),
           extracted.jpeg.isEmpty == false,
           let raw = decode(data: extracted.jpeg, maxPixelSize: maxPixelSize) {
            // Crop FIRST in landscape (Sony letterboxes 3:2 scene into a
            // 4:3 thumb), THEN rotate — reversing the order would crop
            // along the wrong axis after transpose.
            let cropped = cropToCameraAspect3by2(raw)
            let img = OrientationApplier.apply(orientation: extracted.exifOrientation,
                                               to: cropped)
            // Parse the TIFF block from the extracted EXIF.
            let exif: ExifSummary? = extracted.exifBytes.flatMap(TIFFEXIFParser.parse)
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            return (img, exif, Stats(
                fileBytes: extracted.jpeg.count + (extracted.exifBytes?.count ?? 0),
                readMS:    0,
                decodeMS:  elapsed
            ))
        }
        // FALLBACK: ImageIO. No ExifSummary in this path — by the
        // time we're here the file isn't a camera preview we
        // recognise.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return (nil, nil, nil)
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let img = decode(data: data, maxPixelSize: maxPixelSize)
        let t2 = CFAbsoluteTimeGetCurrent()
        return (img, nil, Stats(
            fileBytes: data.count,
            readMS:    (t1 - t0) * 1000.0,
            decodeMS:  (t2 - t1) * 1000.0
        ))
    }

    /// Common shape for the HEIF and JPEG embedded-thumb paths so
    /// the caller above stays uniform. `Extracted` is `HEIFEmbedded
    /// Thumbnail.Extracted` because that's the type that was already
    /// in use here — the JPEG path adapts into it.
    private static func extractEmbedded(from url: URL, ext: String)
        -> HEIFEmbeddedThumbnail.ExtractedThumbnail?
    {
        if ["hif", "heif", "heic"].contains(ext) {
            return try? HEIFEmbeddedThumbnail.extract(from: url)
        }
        if ["jpg", "jpeg"].contains(ext),
           let jpeg = try? JPEGEmbeddedThumbnail.extract(from: url)
        {
            return .init(jpeg: jpeg.jpeg,
                         exifOrientation: jpeg.exifOrientation,
                         exifBytes: jpeg.exifBytes)
        }
        return nil
    }

    /// Convenience: throw away the stats and exif. Kept for any caller
    /// that just wants the image (tests, debugging).
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
