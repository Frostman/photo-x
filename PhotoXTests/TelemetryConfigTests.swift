import XCTest
@testable import PhotoX

/// Locks in the cadence constants AND the human-readable strings so
/// any future change to either has to land in both places at once.
/// Catches the class of bug where a developer bumps the Duration
/// without updating the help-text formatting (or vice versa).
final class TelemetryConfigTests: XCTestCase {

    func test_localPersistInterval_is5Minutes() {
        XCTAssertEqual(TelemetryConfig.localPersistInterval, .seconds(5 * 60))
        XCTAssertEqual(TelemetryConfig.localPersistIntervalDescription, "5 minutes")
    }

    func test_uploadInterval_is6Hours() {
        XCTAssertEqual(TelemetryConfig.uploadInterval, .seconds(6 * 3600))
        XCTAssertEqual(TelemetryConfig.uploadIntervalDescription, "6 hours")
    }
}
