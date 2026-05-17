import XCTest
import CoreGraphics
@testable import PhotoX

/// All-pure-math coverage for the zoom/pan calculator. No UI, no Metal, no
/// fixture files. Each test uses a 8640×5760 "Sony A1 II" image inside a
/// 1600×1000 view as a representative case.
final class CanvasViewportTests: XCTestCase {
    private let image = CGSize(width: 8640, height: 5760)
    private let view  = CGSize(width: 1600, height: 1000)

    // MARK: fitScale

    func test_fitScale_heightConstrained() {
        // 1600/8640 ≈ 0.185, 1000/5760 ≈ 0.173 → min wins, height-limited.
        let s = CanvasViewport.fitScale(imagePixelSize: image, viewPixelSize: view)
        XCTAssertEqual(s, 1000.0 / 5760.0, accuracy: 1e-9)
    }

    func test_fitScale_widthConstrained() {
        // Square view → 1600/8640 < 1600/5760 → width-limited.
        let s = CanvasViewport.fitScale(
            imagePixelSize: image,
            viewPixelSize: CGSize(width: 1600, height: 1600))
        XCTAssertEqual(s, 1600.0 / 8640.0, accuracy: 1e-9)
    }

    func test_fitScale_zeroDimension_returnsIdentity() {
        XCTAssertEqual(CanvasViewport.fitScale(
            imagePixelSize: .zero, viewPixelSize: view), 1.0)
        XCTAssertEqual(CanvasViewport.fitScale(
            imagePixelSize: image, viewPixelSize: .zero), 1.0)
    }

    // MARK: pixelZoom

    func test_pixelZoom_atFit_isFitScale() {
        let vp = CanvasViewport(scale: 1.0)
        XCTAssertEqual(
            vp.pixelZoom(imagePixelSize: image, viewPixelSize: view),
            CanvasViewport.fitScale(imagePixelSize: image, viewPixelSize: view))
    }

    func test_pixelZoom_one_to_one_means_one_image_px_per_device_px() {
        let vp = CanvasViewport.oneToOne(imagePixelSize: image, viewPixelSize: view)
        XCTAssertEqual(vp.pixelZoom(imagePixelSize: image, viewPixelSize: view),
                       1.0, accuracy: 1e-9)
        XCTAssertEqual(vp.offset, .zero)
    }

    // MARK: zoomed — clamping

    func test_zoomed_clamps_to_minScale() {
        let start = CanvasViewport(scale: 1.0)
        let zoomed = start.zoomed(by: 0.001, around: CGPoint(x: 800, y: 500), viewSize: view)
        XCTAssertEqual(zoomed.scale, CanvasViewport.minScale)
    }

    func test_zoomed_clamps_to_maxScale() {
        let start = CanvasViewport(scale: 1.0)
        let zoomed = start.zoomed(by: 1000, around: CGPoint(x: 800, y: 500), viewSize: view)
        XCTAssertEqual(zoomed.scale, CanvasViewport.maxScale)
    }

    func test_zoomed_around_viewCenter_keepsOffsetZero() {
        let start = CanvasViewport(scale: 1.0, offset: .zero)
        let center = CGPoint(x: view.width / 2, y: view.height / 2)
        let zoomed = start.zoomed(by: 2.0, around: center, viewSize: view)
        XCTAssertEqual(zoomed.scale, 2.0, accuracy: 1e-9)
        XCTAssertEqual(zoomed.offset.x, 0, accuracy: 1e-9)
        XCTAssertEqual(zoomed.offset.y, 0, accuracy: 1e-9)
    }

    func test_zoomed_aroundOffCenter_shiftsOffsetTowardFocal() {
        // Zoom in 2x around the top-left corner → offset should move so that
        // pixel-under-cursor stays under cursor: cx=800, cy=500, focal=(0,0)
        // newScale=2 from scale=1, ratio=2 → dx = (0-800)*(1-2) + 0*2 = 800
        let start = CanvasViewport(scale: 1.0, offset: .zero)
        let zoomed = start.zoomed(by: 2.0, around: .zero, viewSize: view)
        XCTAssertEqual(zoomed.offset.x, 800, accuracy: 1e-9)
        XCTAssertEqual(zoomed.offset.y, 500, accuracy: 1e-9)
    }

    // MARK: panned

    func test_panned_addsDelta() {
        let start = CanvasViewport(scale: 1.0, offset: CGPoint(x: 10, y: 20))
        let panned = start.panned(by: CGPoint(x: -3, y: 7))
        XCTAssertEqual(panned.offset.x, 7)
        XCTAssertEqual(panned.offset.y, 27)
        XCTAssertEqual(panned.scale, 1.0)
    }

    // MARK: clampedOffset

    func test_clampedOffset_atFit_imageSmallerThanView_forcesCentered() {
        // At fit, the image is letterboxed inside the view, so on the
        // unconstrained axis the image is *smaller* than the view → maxX/Y = 0
        // → the offset is forced to zero (centered).
        let vp = CanvasViewport(scale: 1.0, offset: CGPoint(x: 500, y: 500))
        let clamped = vp.clampedOffset(imagePixelSize: image, viewPixelSize: view)
        XCTAssertEqual(clamped.offset.x, 0)
        XCTAssertEqual(clamped.offset.y, 0)
    }

    func test_clampedOffset_zoomedIn_limitsPanToImageBounds() {
        // 4x scale: image becomes much larger than view, so panning is allowed
        // but bounded by (imgSize - viewSize) / 2 on each axis.
        let vp = CanvasViewport(scale: 4.0, offset: CGPoint(x: 1_000_000, y: 1_000_000))
        let clamped = vp.clampedOffset(imagePixelSize: image, viewPixelSize: view)
        let fit = CanvasViewport.fitScale(imagePixelSize: image, viewPixelSize: view)
        let effW = image.width * fit * 4
        let effH = image.height * fit * 4
        XCTAssertEqual(clamped.offset.x, (effW - view.width) / 2, accuracy: 1e-9)
        XCTAssertEqual(clamped.offset.y, (effH - view.height) / 2, accuracy: 1e-9)
    }

    func test_clampedOffset_negativeBigOffset_clampedSymmetrically() {
        let vp = CanvasViewport(scale: 4.0, offset: CGPoint(x: -1_000_000, y: -1_000_000))
        let clamped = vp.clampedOffset(imagePixelSize: image, viewPixelSize: view)
        let fit = CanvasViewport.fitScale(imagePixelSize: image, viewPixelSize: view)
        let effW = image.width * fit * 4
        let effH = image.height * fit * 4
        XCTAssertEqual(clamped.offset.x, -(effW - view.width) / 2, accuracy: 1e-9)
        XCTAssertEqual(clamped.offset.y, -(effH - view.height) / 2, accuracy: 1e-9)
    }
}
