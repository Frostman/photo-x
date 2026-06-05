import XCTest
@testable import PhotoX

/// Pins the literal day/month-range output of the deriver. No "dominant
/// month" optimisation — every test asserts the exact string the UI
/// would render in the project-name field.
final class ProjectNameDeriverTests: XCTestCase {

    private let posix = Locale(identifier: "en_US_POSIX")

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func test_emptyDates_returnsFolderName() {
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: [], folderName: "DCIM_001"),
            "DCIM_001")
    }

    func test_singleDay_returnsYearMonthDay() {
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: [date(2026, 3, 14)],
                                      folderName: "x", locale: posix),
            "2026-March-14")
    }

    func test_singleDay_multipleSamples_returnsThatDay() {
        // Multiple EXIF entries on the same day still render as one day.
        let d = date(2026, 3, 14)
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: [d, d, d],
                                      folderName: "x", locale: posix),
            "2026-March-14")
    }

    func test_multiDay_sameMonth_returnsDayRange() {
        let dates = [date(2026, 3, 14), date(2026, 3, 15), date(2026, 3, 18)]
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: dates, folderName: "x", locale: posix),
            "2026-March-14_to_18")
    }

    func test_multiDay_crossMonth_sameYear_returnsMonthDayRange() {
        let dates = [date(2026, 3, 14), date(2026, 4, 2)]
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: dates, folderName: "x", locale: posix),
            "2026-March-14_to_April-02")
    }

    func test_multiDay_crossYear_returnsYearPrefixedRange() {
        let dates = [date(2026, 12, 30), date(2027, 1, 2)]
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: dates, folderName: "x", locale: posix),
            "2026-December-30_to_2027-January-02")
    }

    func test_singleDayDigitMonth_padsToTwoDigits() {
        // March 3rd, not March 3 — preserves the zero-pad invariant
        // (file-system sort friendly).
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: [date(2026, 3, 3)],
                                      folderName: "x", locale: posix),
            "2026-March-03")
    }

    func test_outOfOrderDates_stillUseMinAndMax() {
        // Order of the input array doesn't matter — min/max drive the output.
        let dates = [date(2026, 3, 18), date(2026, 3, 14), date(2026, 3, 15)]
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: dates, folderName: "x", locale: posix),
            "2026-March-14_to_18")
    }

    func test_neverCollapsesMultiDayToMonthOnly() {
        // A 20-day span within one month must still be a day range —
        // the project explicitly opted out of "dominant month" heuristics.
        let dates = [date(2026, 3, 1), date(2026, 3, 20)]
        XCTAssertEqual(
            ProjectNameDeriver.derive(from: dates, folderName: "x", locale: posix),
            "2026-March-01_to_20")
    }
}
