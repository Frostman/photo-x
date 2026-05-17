import XCTest
import CoreGraphics
@testable import PhotoX

/// Unit coverage for the pure parsing helpers inside ExifToolRunner. None of
/// these tests spawn exiftool — they feed mock JSON dictionaries shaped like
/// what `exiftool -j` would emit and check the parsed AF model.
final class ExifToolParserTests: XCTestCase {

    // MARK: transform — all 8 EXIF orientations

    private let rect = CGRect(x: 100, y: 200, width: 60, height: 40)
    private let raw  = CGSize(width: 8640, height: 5760)

    func test_transform_orientation1_isIdentity() {
        XCTAssertEqual(
            ExifToolRunner.transform(rect, orientation: 1, rawSize: raw),
            rect)
    }

    func test_transform_orientation2_mirrorsHorizontally() {
        // (x,y,w,h) → (W - x - w, y, w, h)
        let out = ExifToolRunner.transform(rect, orientation: 2, rawSize: raw)
        XCTAssertEqual(out, CGRect(x: 8640 - 160, y: 200, width: 60, height: 40))
    }

    func test_transform_orientation3_rotates180() {
        // (x,y,w,h) → (W - x - w, H - y - h, w, h)
        let out = ExifToolRunner.transform(rect, orientation: 3, rawSize: raw)
        XCTAssertEqual(out, CGRect(x: 8640 - 160, y: 5760 - 240, width: 60, height: 40))
    }

    func test_transform_orientation4_mirrorsVertically() {
        // (x,y,w,h) → (x, H - y - h, w, h)
        let out = ExifToolRunner.transform(rect, orientation: 4, rawSize: raw)
        XCTAssertEqual(out, CGRect(x: 100, y: 5760 - 240, width: 60, height: 40))
    }

    func test_transform_orientation5_transposesWithSwap() {
        // (x,y,w,h) → (y, x, h, w)
        let out = ExifToolRunner.transform(rect, orientation: 5, rawSize: raw)
        XCTAssertEqual(out, CGRect(x: 200, y: 100, width: 40, height: 60))
    }

    func test_transform_orientation6_rotates90CW() {
        // Portrait shoots usually land here. (x,y,w,h) → (H - y - h, x, h, w)
        let out = ExifToolRunner.transform(rect, orientation: 6, rawSize: raw)
        XCTAssertEqual(out, CGRect(x: 5760 - 240, y: 100, width: 40, height: 60))
    }

    func test_transform_orientation7_mirrorH_rotates90CW() {
        // (x,y,w,h) → (H - y - h, W - x - w, h, w)
        let out = ExifToolRunner.transform(rect, orientation: 7, rawSize: raw)
        XCTAssertEqual(out, CGRect(x: 5760 - 240, y: 8640 - 160, width: 40, height: 60))
    }

    func test_transform_orientation8_rotates270CW() {
        // (x,y,w,h) → (y, W - x - w, h, w)
        let out = ExifToolRunner.transform(rect, orientation: 8, rawSize: raw)
        XCTAssertEqual(out, CGRect(x: 200, y: 8640 - 160, width: 40, height: 60))
    }

    func test_transform_passesThrough_whenRawSizeZero() {
        // Defensive: if rawSize was empty we can't compute mirroring; return
        // the rect unchanged rather than producing nonsense coordinates.
        let out = ExifToolRunner.transform(rect, orientation: 3, rawSize: .zero)
        XCTAssertEqual(out, rect)
    }

    func test_transform_unknownOrientation_returnsRectUnchanged() {
        let out = ExifToolRunner.transform(rect, orientation: 42, rawSize: raw)
        XCTAssertEqual(out, rect)
    }

    // MARK: parseOrientation

    func test_parseOrientation_findsSuffixMatch() {
        XCTAssertEqual(ExifToolRunner.parseOrientation(from: ["IFD0:Orientation": 6]), 6)
        XCTAssertEqual(ExifToolRunner.parseOrientation(from: ["Orientation": 1]), 1)
    }

    func test_parseOrientation_defaultsTo1_whenMissing() {
        XCTAssertEqual(ExifToolRunner.parseOrientation(from: [:]), 1)
        XCTAssertEqual(ExifToolRunner.parseOrientation(from: ["Foo:Bar": 2]), 1)
    }

    // MARK: parseRawImageSize

    func test_parseRawImageSize_extractsFirstTwoIntsFromFocusLocation() {
        let dict: [String: Any] = ["Sony:FocusLocation": "8640 5760 1234 5678"]
        XCTAssertEqual(ExifToolRunner.parseRawImageSize(from: dict),
                       CGSize(width: 8640, height: 5760))
    }

    func test_parseRawImageSize_returnsZero_whenMissing() {
        XCTAssertEqual(ExifToolRunner.parseRawImageSize(from: [:]), .zero)
    }

    // MARK: parseSettings

    func test_parseSettings_collectsAFFields() {
        let dict: [String: Any] = [
            "Sony:FocusMode": "AF-C",
            "Sony:AFAreaModeSetting": "Wide",
            "Sony:AFAreaMode": "Tracking",
            "Sony:AFTracking": "On",
            "Composite:FocusDistance": "1.2 m",
            "Sony:FocalPlaneAFPointsUsed": 9,
            "Sony:FocusFrameSize": "120x120",
        ]
        let s = ExifToolRunner.parseSettings(from: dict)
        XCTAssertEqual(s.focusMode, "AF-C")
        XCTAssertEqual(s.afAreaMode, "Wide / Tracking")
        XCTAssertEqual(s.afTracking, "On")
        XCTAssertEqual(s.focusDistance, "1.2 m")
        XCTAssertEqual(s.pointsUsed, 9)
        XCTAssertEqual(s.focusFrameSize, "120 × 120")
    }

    func test_parseSettings_handlesMissingFields_asNil() {
        let s = ExifToolRunner.parseSettings(from: [:])
        XCTAssertNil(s.focusMode)
        XCTAssertNil(s.afAreaMode)
        XCTAssertNil(s.focusDistance)
        XCTAssertNil(s.pointsUsed)
    }

    func test_parseSettings_prettifiesInfinityDistance() {
        let dict: [String: Any] = ["Composite:FocusDistance": "inf"]
        XCTAssertEqual(ExifToolRunner.parseSettings(from: dict).focusDistance, "∞")
    }

    // MARK: parsePrimaryFocus

    func test_parsePrimaryFocus_buildsCenteredRect_fromFocusLocation() {
        // FocusLocation = "imgW imgH fx fy", frame = "120x120" → rect centered
        // on (fx, fy) with size 120×120.
        let dict: [String: Any] = [
            "Sony:FocusLocation": "8640 5760 4320 2880",
            "Sony:FocusFrameSize": "120x120",
        ]
        let regions = ExifToolRunner.parsePrimaryFocus(dict)
        XCTAssertEqual(regions.count, 1)
        let r = regions[0]
        XCTAssertEqual(r.kind, .primaryFocus)
        XCTAssertEqual(r.rect, CGRect(x: 4320 - 60, y: 2880 - 60, width: 120, height: 120))
        XCTAssertTrue(r.label?.contains("8640") ?? false,
                      "Label should mention image dimensions")
    }

    func test_parsePrimaryFocus_defaultFrameSize_120() {
        let dict: [String: Any] = ["Sony:FocusLocation": "8640 5760 4320 2880"]
        let r = ExifToolRunner.parsePrimaryFocus(dict).first!
        XCTAssertEqual(r.rect.size, CGSize(width: 120, height: 120))
    }

    func test_parsePrimaryFocus_emptyWhenFocusLocationMissing() {
        XCTAssertTrue(ExifToolRunner.parsePrimaryFocus([:]).isEmpty)
    }

    // MARK: parseFocalPlanePoints

    func test_parseFocalPlanePoints_scalesFromInternal640x480Grid() {
        // Sony's internal AF point grid is 640×480. With an 8640×5760 image,
        // a point at (320, 240) → image (4320, 2880), the exact center.
        let dict: [String: Any] = [
            "Sony:FocusLocation": "8640 5760 0 0",
            "Sony:FocalPlaneAFPointLocation1": "320 240",
        ]
        let regions = ExifToolRunner.parseFocalPlanePoints(dict)
        XCTAssertEqual(regions.count, 1)
        let r = regions[0]
        XCTAssertEqual(r.kind, .focalPlanePoint)
        // The dot is at least 80px wide for visibility.
        XCTAssertEqual(r.rect.midX, 4320, accuracy: 0.1)
        XCTAssertEqual(r.rect.midY, 2880, accuracy: 0.1)
    }

    func test_parseFocalPlanePoints_skipsMissingPoints() {
        let dict: [String: Any] = [
            "Sony:FocusLocation": "8640 5760 0 0",
            "Sony:FocalPlaneAFPointLocation3": "100 100",
            "Sony:FocalPlaneAFPointLocation7": "500 400",
        ]
        let regions = ExifToolRunner.parseFocalPlanePoints(dict)
        XCTAssertEqual(regions.count, 2)
    }

    func test_parseFocalPlanePoints_emptyWhenFocusLocationMissing() {
        let dict: [String: Any] = ["Sony:FocalPlaneAFPointLocation1": "100 100"]
        XCTAssertTrue(ExifToolRunner.parseFocalPlanePoints(dict).isEmpty)
    }

    // MARK: parseFaces

    func test_parseFaces_swapsYX_and_HW_perSonyFormat() {
        // Sony writes "y x h w" (yes, in that order) in 640-wide coords.
        // imgW=8640, scale = 8640/640 = 13.5; imgH=5760, scale = 5760/480 = 12.
        // y=100 x=200 h=80 w=60 → rect(x=200*13.5=2700, y=100*12=1200, w=60*13.5=810, h=80*12=960)
        let dict: [String: Any] = [
            "Sony:FocusLocation": "8640 5760 0 0",
            "Sony:Face1Position": "100 200 80 60",
        ]
        let regions = ExifToolRunner.parseFaces(dict)
        XCTAssertEqual(regions.count, 1)
        let r = regions[0]
        XCTAssertEqual(r.kind, .face)
        XCTAssertEqual(r.rect.minX, 2700, accuracy: 0.01)
        XCTAssertEqual(r.rect.minY, 1200, accuracy: 0.01)
        XCTAssertEqual(r.rect.width, 810, accuracy: 0.01)
        XCTAssertEqual(r.rect.height, 960, accuracy: 0.01)
    }

    func test_parseFaces_skipsMalformedEntries() {
        let dict: [String: Any] = [
            "Sony:FocusLocation": "8640 5760 0 0",
            "Sony:Face1Position": "this is not parseable",
            "Sony:Face2Position": "100 200 80 60",
        ]
        XCTAssertEqual(ExifToolRunner.parseFaces(dict).count, 1)
    }

    // MARK: parseRegions — composition

    func test_parseRegions_combinesPrimaryFocalPointsAndFaces() {
        let dict: [String: Any] = [
            "Sony:FocusLocation": "8640 5760 4320 2880",
            "Sony:FocusFrameSize": "120x120",
            "Sony:FocalPlaneAFPointLocation1": "200 150",
            "Sony:FocalPlaneAFPointLocation2": "300 200",
            "Sony:Face1Position": "100 200 80 60",
        ]
        let regions = ExifToolRunner.parseRegions(from: dict)
        let kinds = regions.map(\.kind)
        XCTAssertTrue(kinds.contains(.primaryFocus))
        XCTAssertEqual(kinds.filter { $0 == .focalPlanePoint }.count, 2)
        XCTAssertEqual(kinds.filter { $0 == .face }.count, 1)
    }
}
