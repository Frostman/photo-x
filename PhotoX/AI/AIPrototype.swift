import Accelerate
import CoreGraphics
import Foundation
import OSLog
import Vision

/// Experimental, on-device, displayed-frame-only AI helpers.
///
/// Strict invariants:
/// - Every entry point reads in-memory `CGImage` only; no disk I/O.
/// - No caching across frames; no persistence; no XMP writes.
/// - DEBUG-only timing log lines, gated at the helper source per the
///   release-logs policy.
/// - Callers must gate on the `experimentalAIEnabled` setting before
///   reaching these methods. Methods themselves do no gating — they
///   run whatever the caller asks. The gate lives in the UI layer
///   (sidebar sections + ⇧F handler) where the user choice originates.
/// Cache-friendly value type for scores. Sendable so it crosses
/// actor isolation cleanly when the background compute Task lands
/// on the main actor to write into `ViewerState.entryAIScores`.
struct AICachedScores: Equatable, Sendable {
    var sharpness: Double
    var aesthetic: Double?
    var utility: Bool?
}

/// One (label, confidence) pair — wrapper so the tuple's identity is
/// stable enough for `ForEach` in the sidebar.
struct AIKeywordLabel: Hashable, Sendable, Identifiable {
    let identifier: String
    let confidence: Double
    var id: String { identifier }
}

enum AIPrototype {

    // MARK: Sharpness

    /// Single scalar "how sharp is the displayed frame" in [0, 1].
    /// Computes Laplacian variance on a 512×512 grayscale downsample.
    /// Whole-frame measurement.
    static func computeSharpness(_ cgImage: CGImage) async -> (score: Double, ms: Double) {
        await Task.detached(priority: .userInitiated) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let (gray, w, h) = downsampleToGray8(cgImage, target: 512)
            let value = laplacianVarianceNormalized(gray: gray, width: w, height: h)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log(label: "sharpness", ms: ms, extra: "score=\(value)")
            return (value, ms)
        }.value
    }

    // MARK: Aesthetic

    /// Apple's macOS 15 `CalculateImageAestheticsScoresRequest`.
    /// `overall` is in `[-1, 1]` (normalised to `[0, 1]` for display).
    /// `isUtility` flags screenshots / receipts / non-photographic.
    /// Returns `nil` if Vision rejects the input.
    static func computeAesthetic(_ cgImage: CGImage) async -> (overall: Double, utility: Bool, ms: Double)? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let request = CalculateImageAestheticsScoresRequest()
        do {
            let observation = try await request.perform(on: cgImage)
            let raw = Double(observation.overallScore)
            let normalized = max(0.0, min(1.0, (raw + 1.0) / 2.0))
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log(label: "aesthetic", ms: ms, extra: "overall=\(raw) utility=\(observation.isUtility)")
            return (normalized, observation.isUtility, ms)
        } catch {
            #if DEBUG
            logger.notice("aesthetic failed: \(String(describing: error), privacy: .public)")
            #endif
            return nil
        }
    }

    // MARK: Keywords (classification)

    /// `ClassifyImageRequest`-backed top-K labels. Filtered to
    /// observations with confidence ≥ `minConfidence`. Not written
    /// anywhere — caller renders inline.
    static func computeKeywords(
        _ cgImage: CGImage,
        minConfidence: Double = 0.5,
        topK: Int = 10
    ) async -> (labels: [(String, Double)], ms: Double) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let request = ClassifyImageRequest()
        do {
            let observations = try await request.perform(on: cgImage)
            let filtered = observations
                .filter { Double($0.confidence) >= minConfidence }
                .prefix(topK)
                .map { ($0.identifier, Double($0.confidence)) }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log(label: "keywords", ms: ms, extra: "n=\(filtered.count)")
            return (Array(filtered), ms)
        } catch {
            #if DEBUG
            logger.notice("keywords failed: \(String(describing: error), privacy: .public)")
            #endif
            return ([], (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
    }

    // MARK: Heatmap

    /// Per-tile Laplacian-variance heatmap rendered as a CGImage with
    /// premultiplied alpha. Caller overlays it on the canvas at the
    /// same fit/zoom as the photo. `tiles` is the grid resolution on
    /// the long edge (default 64 → ~64×N depending on aspect).
    static func computeHeatmap(_ cgImage: CGImage, tiles: Int = 64) async -> (image: CGImage, ms: Double)? {
        await Task.detached(priority: .userInitiated) {
            let t0 = CFAbsoluteTimeGetCurrent()
            // Work on a downsampled grayscale buffer. The tile grid
            // is computed in this downsampled space — never on
            // full-res pixels (irrelevant overhead).
            let longEdge = 768
            let (gray, w, h) = downsampleToGray8(cgImage, target: longEdge)
            guard w > 0, h > 0 else { return nil }
            let tileW = max(1, w / max(1, tiles))
            let tileH = tileW  // square tiles in pixel space
            let gridW = w / tileW
            let gridH = h / tileH
            guard gridW > 0, gridH > 0 else { return nil }
            var tileScores = [Double](repeating: 0, count: gridW * gridH)
            for ty in 0..<gridH {
                for tx in 0..<gridW {
                    let v = tileVariance(
                        gray: gray,
                        width: w,
                        x0: tx * tileW,
                        y0: ty * tileH,
                        tileW: tileW,
                        tileH: tileH
                    )
                    tileScores[ty * gridW + tx] = v
                }
            }
            // Normalise to [0, 1] using a soft percentile so outliers
            // don't compress the dynamic range. Use the 95th
            // percentile as the upper bound.
            let sorted = tileScores.sorted()
            let pIdx = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
            let upper = max(sorted[pIdx], 1.0)
            for i in 0..<tileScores.count {
                tileScores[i] = min(1.0, tileScores[i] / upper)
            }
            // Render an RGBA image at the grid resolution. Caller
            // scales it to fit the canvas via SwiftUI's
            // `.interpolation(.medium)`, so we don't pre-blur here.
            guard let image = renderHeatmapImage(scores: tileScores, gridW: gridW, gridH: gridH) else {
                return nil
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log(label: "heatmap", ms: ms, extra: "grid=\(gridW)x\(gridH)")
            return (image, ms)
        }.value
    }

    // MARK: - Private: downsample + math

    /// Render a CGImage into a fresh single-channel 8-bit grayscale
    /// buffer downsampled so the long edge ≤ `target`. Returns the
    /// pixel buffer plus the output width/height.
    private static func downsampleToGray8(_ cgImage: CGImage, target: Int) -> ([UInt8], Int, Int) {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { return ([], 0, 0) }
        let scale = Double(target) / Double(max(srcW, srcH))
        let outW = max(1, Int(Double(srcW) * scale))
        let outH = max(1, Int(Double(srcH) * scale))
        guard let cs = CGColorSpace(name: CGColorSpace.linearGray) else { return ([], 0, 0) }
        var buf = [UInt8](repeating: 0, count: outW * outH)
        let bytesPerRow = outW
        let bitmapInfo: UInt32 = CGImageAlphaInfo.none.rawValue
        guard let ctx = buf.withUnsafeMutableBytes({ raw -> CGContext? in
            guard let base = raw.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: bitmapInfo
            )
        }) else { return ([], 0, 0) }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return (buf, outW, outH)
    }

    /// Variance of the Laplacian over a grayscale buffer, normalised
    /// to roughly [0, 1] via a divisor calibrated on test fixtures.
    private static func laplacianVarianceNormalized(
        gray: [UInt8],
        width: Int,
        height: Int
    ) -> Double {
        guard width >= 3, height >= 3 else { return 0 }
        var sum = 0.0
        var sumSq = 0.0
        var n = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let c = Int(gray[y * width + x])
                let l = Int(gray[y * width + (x - 1)])
                let r = Int(gray[y * width + (x + 1)])
                let u = Int(gray[(y - 1) * width + x])
                let d = Int(gray[(y + 1) * width + x])
                let lap = Double(4 * c - l - r - u - d)
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / Double(n)
        let variance = max(0, sumSq / Double(n) - mean * mean)
        // 2500 chosen empirically: a clean, well-focused HEIF lands
        // around 0.6–0.8, defocused / motion-blurred lands < 0.1.
        // Easy to retune — it's prototype scaling, not a model
        // coefficient.
        let scaled = variance / 2500.0
        return min(1.0, scaled)
    }

    /// Variance of the Laplacian over a single tile of the grayscale
    /// buffer. Unnormalised — the heatmap pipeline normalises after
    /// collecting all tiles.
    private static func tileVariance(
        gray: [UInt8],
        width: Int,
        x0: Int,
        y0: Int,
        tileW: Int,
        tileH: Int
    ) -> Double {
        var sum = 0.0
        var sumSq = 0.0
        var n = 0
        let xEnd = x0 + tileW
        let yEnd = y0 + tileH
        for y in max(1, y0)..<min(yEnd, width > 0 ? gray.count / width - 1 : 0) {
            for x in max(1, x0)..<min(xEnd, width - 1) {
                let c = Int(gray[y * width + x])
                let l = Int(gray[y * width + (x - 1)])
                let r = Int(gray[y * width + (x + 1)])
                let u = Int(gray[(y - 1) * width + x])
                let d = Int(gray[(y + 1) * width + x])
                let lap = Double(4 * c - l - r - u - d)
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / Double(n)
        return max(0, sumSq / Double(n) - mean * mean)
    }

    /// Build an RGBA8 CGImage from per-tile scores using a viridis-ish
    /// blue→green→yellow→red colormap. Alpha is proportional to
    /// score so low-detail tiles fade into the background.
    private static func renderHeatmapImage(scores: [Double], gridW: Int, gridH: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: gridW * gridH * 4)
        for i in 0..<scores.count {
            let s = scores[i]
            let (r, g, b) = heatmapColor(for: s)
            let alpha = UInt8(min(255.0, max(0.0, s * 230.0)))
            let base = i * 4
            pixels[base + 0] = r
            pixels[base + 1] = g
            pixels[base + 2] = b
            pixels[base + 3] = alpha
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = gridW * 4
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
                               | CGBitmapInfo.byteOrderDefault.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: gridW,
            height: gridH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Cool→hot colormap. `s` in [0, 1]. Tuned to keep low values
    /// quiet (dark blue, near-transparent) and high values vivid.
    private static func heatmapColor(for s: Double) -> (UInt8, UInt8, UInt8) {
        // Three-stop interpolation: blue (#1f3a93) → green (#5fd35f)
        // → red (#e23636).
        let clamped = min(1.0, max(0.0, s))
        let stops: [(t: Double, r: Double, g: Double, b: Double)] = [
            (0.0, 31,  58,  147),
            (0.5, 95,  211, 95),
            (1.0, 226, 54,  54),
        ]
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if clamped <= b.t {
                let span = b.t - a.t
                let t = span > 0 ? (clamped - a.t) / span : 0
                let r = a.r + (b.r - a.r) * t
                let g = a.g + (b.g - a.g) * t
                let bl = a.b + (b.b - a.b) * t
                return (UInt8(r), UInt8(g), UInt8(bl))
            }
        }
        let last = stops.last!
        return (UInt8(last.r), UInt8(last.g), UInt8(last.b))
    }

    // MARK: - Logging

    #if DEBUG
    private static let logger = Logger(subsystem: "dev.frostman.PhotoX", category: "ai")
    #endif

    private static func log(label: String, ms: Double, extra: String = "") {
        #if DEBUG
        logger.notice("\(label, privacy: .public) \(ms, format: .fixed(precision: 1))ms \(extra, privacy: .public)")
        #else
        _ = (label, ms, extra)
        #endif
    }
}
