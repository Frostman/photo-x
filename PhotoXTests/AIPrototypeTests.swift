import CoreGraphics
import XCTest
@testable import PhotoX

/// Coverage for the on-device AI prototype helpers. The helpers run
/// against in-memory CGImages — these tests build synthetic images so
/// the fixtures are deterministic and the suite stays hermetic.
@MainActor
final class AIPrototypeTests: XCTestCase {

    // MARK: Sharpness ordering

    /// A flat-grey image has near-zero Laplacian variance; a
    /// high-frequency checkerboard maxes it out. The score must
    /// reflect that ordering — sharp > blurry — within the [0, 1]
    /// normalisation.
    func test_sharpness_ordersSharpAboveBlurry() async {
        let flat = makeFlatImage(width: 256, height: 256, gray: 128)
        let checker = makeCheckerImage(width: 256, height: 256, cell: 4)
        let (blurryScore, _) = await AIPrototype.computeSharpness(flat)
        let (sharpScore, _)  = await AIPrototype.computeSharpness(checker)
        XCTAssertLessThan(blurryScore, sharpScore, "blurry should score below sharp")
        XCTAssertLessThan(blurryScore, 0.05, "flat grey should be ~0")
        XCTAssertGreaterThan(sharpScore, 0.5, "high-frequency checker should be ≥ 0.5")
    }

    func test_sharpness_returnsInRange() async {
        let img = makeFlatImage(width: 64, height: 64, gray: 200)
        let (score, ms) = await AIPrototype.computeSharpness(img)
        XCTAssertGreaterThanOrEqual(score, 0)
        XCTAssertLessThanOrEqual(score, 1)
        XCTAssertGreaterThan(ms, 0)
    }

    // MARK: Aesthetic

    func test_aesthetic_returnsObservation() async {
        // Aesthetics may legitimately reject synthetic images; what we
        // pin is that the helper returns *something* (success or nil)
        // without throwing on an in-range CGImage.
        let img = makeCheckerImage(width: 128, height: 128, cell: 8)
        let result = await AIPrototype.computeAesthetic(img)
        if let r = result {
            XCTAssertGreaterThanOrEqual(r.overall, 0)
            XCTAssertLessThanOrEqual(r.overall, 1)
            XCTAssertGreaterThan(r.ms, 0)
        }
    }

    // MARK: Keywords

    func test_keywords_returnsArray() async {
        let img = makeCheckerImage(width: 224, height: 224, cell: 16)
        let result = await AIPrototype.computeKeywords(img, minConfidence: 0.0, topK: 5)
        // We don't assert on labels (synthetic input has no
        // ground-truth class) — we assert the helper plumbed through
        // without throwing and respected `topK`.
        XCTAssertLessThanOrEqual(result.labels.count, 5)
        XCTAssertGreaterThan(result.ms, 0)
    }

    func test_keywords_filtersBelowConfidence() async {
        let img = makeCheckerImage(width: 224, height: 224, cell: 16)
        let result = await AIPrototype.computeKeywords(img, minConfidence: 1.1, topK: 10)
        // No real classification will reach confidence > 1.0.
        XCTAssertTrue(result.labels.isEmpty)
    }

    // MARK: Heatmap

    func test_heatmap_returnsImage() async {
        let img = makeCheckerImage(width: 256, height: 256, cell: 4)
        let result = await AIPrototype.computeHeatmap(img, tiles: 32)
        XCTAssertNotNil(result)
        if let r = result {
            XCTAssertGreaterThan(r.image.width, 0)
            XCTAssertGreaterThan(r.image.height, 0)
            XCTAssertGreaterThan(r.ms, 0)
        }
    }

    // MARK: Fixtures

    private func makeFlatImage(width: Int, height: Int, gray: UInt8) -> CGImage {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i + 0] = gray
            bytes[i + 1] = gray
            bytes[i + 2] = gray
            bytes[i + 3] = 255
        }
        return makeCGImage(bytes: bytes, width: width, height: height)
    }

    private func makeCheckerImage(width: Int, height: Int, cell: Int) -> CGImage {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                let v: UInt8 = on ? 255 : 0
                let base = y * bytesPerRow + x * 4
                bytes[base + 0] = v
                bytes[base + 1] = v
                bytes[base + 2] = v
                bytes[base + 3] = 255
            }
        }
        return makeCGImage(bytes: bytes, width: width, height: height)
    }

    private func makeCGImage(bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
                               | CGBitmapInfo.byteOrderDefault.rawValue
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
