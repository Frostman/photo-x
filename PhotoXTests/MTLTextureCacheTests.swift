import CoreGraphics
import Metal
import XCTest
@testable import PhotoX

/// Tests the LRU + single-flight semantics of `MTLTextureCache`. The
/// cache is a singleton in production (process-wide), so each test
/// starts by `clear()`-ing it. Tests use a tiny CGImage so MTKTextureLoader
/// stays cheap.
final class MTLTextureCacheTests: XCTestCase {

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        MTLTextureCache.shared.clear()
    }

    @MainActor
    override func tearDown() async throws {
        MTLTextureCache.shared.clear()
        try await super.tearDown()
    }

    // MARK: - basics

    @MainActor
    func test_get_missingKey_returnsNil() {
        XCTAssertNil(MTLTextureCache.shared.get(key(id: "missing")))
        XCTAssertEqual(MTLTextureCache.shared.count, 0)
    }

    @MainActor
    func test_warm_insertsEntry_andGetReturnsIt() async throws {
        let k = key(id: "a")
        let img = tinyImage()
        let entry = try await MTLTextureCache.shared.warm(cgImage: img, key: k, orientation: 1)
        XCTAssertEqual(entry.pixelSize, CGSize(width: img.width, height: img.height))
        XCTAssertEqual(entry.orientation, 1)
        XCTAssertEqual(MTLTextureCache.shared.count, 1)

        let again = MTLTextureCache.shared.get(k)
        XCTAssertNotNil(again)
        XCTAssertTrue(again?.texture === entry.texture)
    }

    @MainActor
    func test_warm_swapsWidthHeight_forPortraitOrientations() async throws {
        let img = tinyImage()  // 4×2 (W×H)
        let entry = try await MTLTextureCache.shared.warm(cgImage: img, key: key(id: "p"), orientation: 6)
        XCTAssertEqual(entry.pixelSize, CGSize(width: img.height, height: img.width),
                       "EXIF orientation 6 (90 CW) should expose H×W to callers")
        XCTAssertEqual(entry.orientation, 6)
    }

    // MARK: - LRU eviction

    @MainActor
    func test_capacityCap_evictsLRU_atTwentyEntries() async throws {
        // Use a tiny capacity-equivalent test: warm 21 distinct keys.
        // Slot 0 should be evicted by the 21st insert.
        for i in 0 ..< 21 {
            _ = try await MTLTextureCache.shared.warm(cgImage: tinyImage(), key: key(id: "k\(i)"), orientation: 1)
        }
        XCTAssertEqual(MTLTextureCache.shared.count, 20)
        XCTAssertNil(MTLTextureCache.shared.get(key(id: "k0")),
                     "k0 should have been evicted as LRU")
        XCTAssertNotNil(MTLTextureCache.shared.get(key(id: "k20")))
    }

    @MainActor
    func test_get_bumpsMRU_protectingFromEviction() async throws {
        // Insert k0..k19, then access k0 → k0 becomes MRU. Inserting
        // k20 should evict k1 (now LRU), NOT k0.
        for i in 0 ..< 20 {
            _ = try await MTLTextureCache.shared.warm(cgImage: tinyImage(), key: key(id: "k\(i)"), orientation: 1)
        }
        _ = MTLTextureCache.shared.get(key(id: "k0"))   // bump
        _ = try await MTLTextureCache.shared.warm(cgImage: tinyImage(), key: key(id: "k20"), orientation: 1)
        XCTAssertNotNil(MTLTextureCache.shared.get(key(id: "k0")), "k0 was MRU, must not evict")
        XCTAssertNil(MTLTextureCache.shared.get(key(id: "k1")), "k1 should now be LRU and evicted")
    }

    // MARK: - clear

    @MainActor
    func test_clear_dropsAllEntries() async throws {
        _ = try await MTLTextureCache.shared.warm(cgImage: tinyImage(), key: key(id: "a"), orientation: 1)
        _ = try await MTLTextureCache.shared.warm(cgImage: tinyImage(), key: key(id: "b"), orientation: 1)
        XCTAssertEqual(MTLTextureCache.shared.count, 2)
        MTLTextureCache.shared.clear()
        XCTAssertEqual(MTLTextureCache.shared.count, 0)
        XCTAssertNil(MTLTextureCache.shared.get(key(id: "a")))
    }

    // MARK: - single-flight dedup

    @MainActor
    func test_concurrentWarm_sameKey_sharesUnderlyingUpload() async throws {
        let k = key(id: "shared")
        let img = tinyImage()
        async let a = MTLTextureCache.shared.warm(cgImage: img, key: k, orientation: 1)
        async let b = MTLTextureCache.shared.warm(cgImage: img, key: k, orientation: 1)
        let (ea, eb) = try await (a, b)
        // Both completions must observe the same MTLTexture instance —
        // proves the second caller awaited the first's task rather than
        // starting its own upload.
        XCTAssertTrue(ea.texture === eb.texture)
        XCTAssertEqual(MTLTextureCache.shared.count, 1)
    }

    // MARK: - helpers

    private func key(id: String) -> DecodeKey {
        DecodeKey(pairID: id, variant: .heif, decoder: .imageIO)
    }

    /// 4×2 BGRA bitmap — minimal valid CGImage for MTKTextureLoader.
    private func tinyImage() -> CGImage {
        let width = 4
        let height = 2
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue
                   | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: bitmap
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
