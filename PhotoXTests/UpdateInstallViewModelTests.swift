import XCTest
@testable import PhotoX

@MainActor
final class UpdateInstallViewModelTests: XCTestCase {
    func test_initialState_isAvailable_withEmptyFields() {
        let m = UpdateInstallViewModel()
        XCTAssertEqual(m.stage, .available)
        XCTAssertEqual(m.newVersion, "")
        XCTAssertEqual(m.currentVersion, "")
        XCTAssertNil(m.releaseNotesHTML)
        XCTAssertFalse(m.releaseNotesFailed)
        XCTAssertEqual(m.totalBytes, 0)
        XCTAssertEqual(m.receivedBytes, 0)
        XCTAssertEqual(m.extractionProgress, 0)
        XCTAssertTrue(m.actionsEnabled)
    }

    func test_resetForNewUpdate_seedsAvailableStage() {
        let m = UpdateInstallViewModel()
        m.stage = .extracting
        m.receivedBytes = 999
        m.releaseNotesFailed = true
        m.actionsEnabled = false

        m.resetForNewUpdate(newVersion: "0.7.0", currentVersion: "0.6.0")

        XCTAssertEqual(m.stage, .available)
        XCTAssertEqual(m.newVersion, "0.7.0")
        XCTAssertEqual(m.currentVersion, "0.6.0")
        XCTAssertNil(m.releaseNotesHTML)
        XCTAssertFalse(m.releaseNotesFailed)
        XCTAssertEqual(m.totalBytes, 0)
        XCTAssertEqual(m.receivedBytes, 0)
        XCTAssertEqual(m.extractionProgress, 0)
        XCTAssertTrue(m.actionsEnabled)
    }

    func test_downloadFraction_zeroBeforeContentLengthSet() {
        let m = UpdateInstallViewModel()
        m.receivedBytes = 1_000_000
        XCTAssertEqual(m.downloadFraction, 0,
                       "Without a totalBytes denominator the bar must read 0")
    }

    func test_downloadFraction_clampsAtOne() {
        let m = UpdateInstallViewModel()
        m.totalBytes = 100
        m.receivedBytes = 150  // server lied about content length
        XCTAssertEqual(m.downloadFraction, 1.0,
                       "Over-reported bytes must not push the bar past 1.0")
    }

    func test_progressIndeterminate_perStage() {
        let m = UpdateInstallViewModel()

        // Available + Installing → determinate (no bar shown anyway)
        m.stage = .available
        XCTAssertFalse(m.progressIndeterminate)
        m.stage = .installing
        XCTAssertFalse(m.progressIndeterminate)

        // Downloading before content length → indeterminate
        m.stage = .downloading
        XCTAssertTrue(m.progressIndeterminate)
        m.totalBytes = 100
        XCTAssertFalse(m.progressIndeterminate)

        // Extracting before first progress tick → indeterminate
        m.stage = .extracting
        m.extractionProgress = 0
        XCTAssertTrue(m.progressIndeterminate)
        m.extractionProgress = 0.1
        XCTAssertFalse(m.progressIndeterminate)
    }

    func test_progressLabel_perStage() {
        let m = UpdateInstallViewModel()
        m.stage = .available
        XCTAssertEqual(m.progressLabel, "")

        m.stage = .downloading
        XCTAssertEqual(m.progressLabel, "Starting download…")
        m.totalBytes = 80_000_000
        m.receivedBytes = 40_000_000
        XCTAssertTrue(m.progressLabel.contains("of"),
                      "Expected 'X MB of Y MB' once content length is known, got \(m.progressLabel)")

        m.stage = .extracting
        XCTAssertEqual(m.progressLabel, "Preparing update…")

        m.stage = .installing
        XCTAssertTrue(m.progressLabel.contains("relaunch"),
                      "Installing label should mention relaunch, got \(m.progressLabel)")
    }

    func test_byteFormatter_emitsHumanReadableUnits() {
        XCTAssertEqual(UpdateInstallViewModel.format(bytes: 0), "Zero KB")
        let mb = UpdateInstallViewModel.format(bytes: 50_000_000)
        XCTAssertTrue(mb.contains("MB"), "Expected MB unit, got \(mb)")
    }
}
