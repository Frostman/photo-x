import CoreGraphics
import XCTest
@testable import PhotoX

/// Coverage for the pure viewport-mirror transform used by the external
/// display window to follow the main canvas's zoom + pan proportionally.
final class ExternalViewportTransformTests: XCTestCase {

    private let image = CGSize(width: 8640, height: 5760)

    // MARK: - identity / degenerate guards

    func test_zeroImageSize_returnsIdentity() {
        let vp = ExternalViewportTransform.externalViewport(
            mainViewport: CanvasViewport(scale: 2, offset: CGPoint(x: 100, y: 50)),
            mainPixelZoom: 0.5,
            imagePixelSize: .zero,
            externalViewPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(vp, .identity)
    }

    func test_zeroExternalSize_returnsIdentity() {
        let vp = ExternalViewportTransform.externalViewport(
            mainViewport: CanvasViewport(scale: 2, offset: CGPoint(x: 100, y: 50)),
            mainPixelZoom: 0.5,
            imagePixelSize: image,
            externalViewPixelSize: .zero
        )
        XCTAssertEqual(vp, .identity)
    }

    func test_zeroPixelZoom_returnsIdentity() {
        let vp = ExternalViewportTransform.externalViewport(
            mainViewport: CanvasViewport(scale: 2, offset: CGPoint(x: 100, y: 50)),
            mainPixelZoom: 0,
            imagePixelSize: image,
            externalViewPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(vp, .identity)
    }

    func test_zeroMainScale_returnsIdentity() {
        let vp = ExternalViewportTransform.externalViewport(
            mainViewport: CanvasViewport(scale: 0, offset: .zero),
            mainPixelZoom: 0.5,
            imagePixelSize: image,
            externalViewPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(vp, .identity)
    }

    // MARK: - same-size windows

    func test_sameSizeWindows_copyViewportVerbatim() {
        // Main canvas and external are the same size → external sees the
        // exact same viewport (scale + offset unchanged).
        let mainSize = CGSize(width: 4000, height: 3000)
        let mainFit = CanvasViewport.fitScale(imagePixelSize: image, viewPixelSize: mainSize)
        let scale: CGFloat = 1.5
        let mainPixelZoom = mainFit * scale

        let result = ExternalViewportTransform.externalViewport(
            mainViewport: CanvasViewport(scale: scale, offset: CGPoint(x: 200, y: 80)),
            mainPixelZoom: mainPixelZoom,
            imagePixelSize: image,
            externalViewPixelSize: mainSize
        )

        XCTAssertEqual(result.scale, scale, accuracy: 1e-9)
        XCTAssertEqual(result.offset.x, 200, accuracy: 1e-9)
        XCTAssertEqual(result.offset.y, 80, accuracy: 1e-9)
    }

    // MARK: - proportional offset scaling

    func test_halfSizeExternal_halvesOffset() {
        // External fit is half the main fit → pan offsets scale by 1/2.
        // Image: 8000×4000 (2:1).
        // Main view: 8000×4000 — fit = 1.0 (one image-pixel per device-pixel).
        // External view: 4000×2000 — fit = 0.5.
        // Ratio = 0.5 → offset halves; scale unchanged.
        let img = CGSize(width: 8000, height: 4000)
        let main = CGSize(width: 8000, height: 4000)
        let ext = CGSize(width: 4000, height: 2000)
        let scale: CGFloat = 2.0
        let mainFit = CanvasViewport.fitScale(imagePixelSize: img, viewPixelSize: main)  // 1.0
        let mainPixelZoom = mainFit * scale  // 2.0

        let result = ExternalViewportTransform.externalViewport(
            mainViewport: CanvasViewport(scale: scale, offset: CGPoint(x: 1000, y: 400)),
            mainPixelZoom: mainPixelZoom,
            imagePixelSize: img,
            externalViewPixelSize: ext
        )

        XCTAssertEqual(result.scale, scale, accuracy: 1e-9)
        XCTAssertEqual(result.offset.x, 500, accuracy: 1e-9)
        XCTAssertEqual(result.offset.y, 200, accuracy: 1e-9)
    }

    func test_doubleSizeExternal_doublesOffset() {
        // External is twice the main → external fit is 2× main fit →
        // offsets double.
        let img = CGSize(width: 8000, height: 4000)
        let main = CGSize(width: 4000, height: 2000)
        let ext = CGSize(width: 8000, height: 4000)
        let scale: CGFloat = 1.0
        let mainFit = CanvasViewport.fitScale(imagePixelSize: img, viewPixelSize: main)
        let mainPixelZoom = mainFit * scale

        let result = ExternalViewportTransform.externalViewport(
            mainViewport: CanvasViewport(scale: scale, offset: CGPoint(x: 250, y: -100)),
            mainPixelZoom: mainPixelZoom,
            imagePixelSize: img,
            externalViewPixelSize: ext
        )

        XCTAssertEqual(result.scale, scale, accuracy: 1e-9)
        XCTAssertEqual(result.offset.x, 500, accuracy: 1e-9)
        XCTAssertEqual(result.offset.y, -200, accuracy: 1e-9)
    }

    func test_offsetZero_remainsZero_regardlessOfRatio() {
        // No pan → external also no pan; only scale propagates.
        let img = CGSize(width: 6000, height: 4000)
        let main = CGSize(width: 1200, height: 800)
        let ext = CGSize(width: 600, height: 400)
        let scale: CGFloat = 4.0
        let mainPixelZoom = CanvasViewport.fitScale(imagePixelSize: img, viewPixelSize: main) * scale

        let result = ExternalViewportTransform.externalViewport(
            mainViewport: CanvasViewport(scale: scale, offset: .zero),
            mainPixelZoom: mainPixelZoom,
            imagePixelSize: img,
            externalViewPixelSize: ext
        )

        XCTAssertEqual(result.scale, scale, accuracy: 1e-9)
        XCTAssertEqual(result.offset, .zero)
    }
}
