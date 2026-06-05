import Foundation
import XCTest

/// XCUITest coverage for the three on-canvas overlay toggles —
/// `A` (AF points), `C` (clipping), `F` (focus peaking) — handled
/// in `ContentView.handleKeyDown` at lines 904–909.
///
/// The overlays render directly into the Metal canvas (not the
/// AX tree), so XCUITest can't observe them visually. The
/// `dev.frostman.PhotoX.uitest.readOverlays` Darwin hook writes
/// the current `state.overlays.{afPoints,clipping,focusPeaking}`
/// to a JSON payload file each test reads back. See
/// `PhotoX/Testing/UITestResetObserver.swift::handleReadOverlays`.
///
/// Session base — the keypress + readback pair is fast (~50 ms),
/// and the per-test reset hook resets `state.overlays = .init()`
/// (all three off) via `ViewerState.resetForUITest`.
final class OverlayToggleTests: PhotoXSessionUITestCase {

    private struct OverlaysSnapshot: Decodable {
        let afPoints: Bool
        let clipping: Bool
        let focusPeaking: Bool
    }

    /// Drive the readOverlays Darwin hook and decode the payload.
    private func readOverlays() throws -> OverlaysSnapshot {
        let payloadDir = NSTemporaryDirectory()
        let payload = URL(fileURLWithPath: payloadDir)
            .appendingPathComponent("readOverlays.json")
        try? FileManager.default.removeItem(at: payload)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.readOverlays",
            completion: "dev.frostman.PhotoX.uitest.readOverlaysCompleted",
            timeout:    3
        )
        let data = try Data(contentsOf: payload)
        return try JSONDecoder().decode(OverlaysSnapshot.self, from: data)
    }

    func test_A_togglesAFPoints() throws {
        _ = waitForShootLoaded()
        XCTAssertFalse(try readOverlays().afPoints,
                       "AF-points overlay should start off after session reset")
        pressKey("A")
        XCTAssertTrue(try readOverlays().afPoints,
                      "A should turn AF-points overlay on")
        pressKey("A")
        XCTAssertFalse(try readOverlays().afPoints,
                       "A again should turn AF-points overlay off")
    }

    func test_C_togglesClipping() throws {
        _ = waitForShootLoaded()
        XCTAssertFalse(try readOverlays().clipping,
                       "clipping overlay should start off after session reset")
        pressKey("C")
        XCTAssertTrue(try readOverlays().clipping,
                      "C should turn clipping overlay on")
    }

    func test_F_togglesFocusPeaking() throws {
        _ = waitForShootLoaded()
        XCTAssertFalse(try readOverlays().focusPeaking,
                       "focus-peaking overlay should start off after session reset")
        pressKey("F")
        XCTAssertTrue(try readOverlays().focusPeaking,
                      "F should turn focus-peaking overlay on")
    }
}
