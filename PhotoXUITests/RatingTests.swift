import XCTest

/// Reject (`R`) and color labels (⇧1-5) — both write XMP sidecars
/// via the same setRating / setLabel code path that bare star
/// ratings use, so this pair covers the keyboard-XMP-write contract.
///
/// A bare-digit star test ("3" → ★★★) is intentionally omitted:
/// XCUITest's typeKey delivers plain ASCII digits to SwiftUI
/// .onKeyPress *twice* per call, so the rating toggle round-trips
/// back to nil before the XMP write completes. The bug is in the
/// test harness, not the app — and adding a click-on-star-button
/// test would shadow the keyboard one without exercising the same
/// path. Revisit when the harness gets a single-fire digit helper.
final class RatingTests: PhotoXSessionUITestCase {

    func test_reject_writesNegativeOneRating() throws {
        waitForShootLoaded()
        let stem = try XCTUnwrap(sortedPairStems().first)

        pressKey("R")
        Thread.sleep(forTimeInterval: 0.5)

        let xmp = xmpSidecar(forPairNamed: stem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmp.path),
                      "R should produce a sidecar")
        let body = try String(contentsOf: xmp, encoding: .utf8)
        XCTAssertTrue(body.contains("xmp:Rating=\"-1\"") || body.contains("xmp:Rating>-1</"),
                      "Reject should write xmp:Rating=-1; got:\n\(body.prefix(400))")
    }

    func test_colorLabel_setViaShiftKey() throws {
        waitForShootLoaded()
        let stem = try XCTUnwrap(sortedPairStems().first)

        // ⇧3 → "#" → Green label (1=Red, 2=Yellow, 3=Green,
        // 4=Blue, 5=Purple). macOS converts shift+3 to "#" at the
        // OS layer, which matches .onKeyPress(keys: ["#"]).
        pressKey("3", modifiers: .shift)
        Thread.sleep(forTimeInterval: 0.5)

        let xmp = xmpSidecar(forPairNamed: stem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmp.path),
                      "label set should produce a sidecar")
        let body = try String(contentsOf: xmp, encoding: .utf8)
        XCTAssertTrue(body.contains("xmp:Label=\"Green\"") || body.contains("xmp:Label>Green</"),
                      "⇧3 should set xmp:Label=Green; got:\n\(body.prefix(400))")
    }
}
