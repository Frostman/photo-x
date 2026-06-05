import XCTest

/// XCUITest coverage for the J-key jump-to overlay
/// (`PhotoX/JumpToView.swift`). `J` (handled at
/// `ContentView.handleKeyDown` ~line 928) toggles
/// `showJumpSheet`, which mounts `JumpToView` over the canvas.
///
/// `JumpToView.resolveTargetIndex()` accepts three input shapes,
/// in priority order:
///   1. Numeric in [1, count] → 1-based sortedEntries index.
///   2. Exact stem match → that entry's index.
///   3. First substring suggestion → its index.
///
/// The overlay's AX identifiers (`jumpTo.overlay`, `jumpTo.query`)
/// already exist on the SwiftUI ZStack + TextField.
///
/// Sample fixture (61 entries, `.name` sort): index 1 = DSC00060,
/// index 2 = DSC02115, index 5 = DSC04178 (per the sorted-stems
/// pattern visible in the filmstrip AX-tree at launch).
final class JumpToTests: PhotoXSessionUITestCase {

    private var overlay: XCUIElement {
        // `.accessibilityElement(children: .contain)` on JumpToView's
        // ZStack produces a `Group`-type AX element with this id;
        // children (TextField, suggestion Buttons, …) keep their own
        // identifiers under the container. See HelpOverlayTests for
        // the matching pattern.
        app.groups["jumpTo.overlay"]
    }

    private var queryField: XCUIElement {
        app.textFields["jumpTo.query"]
    }

    /// Wait for the stem pill to show `expectedStem`. Used after
    /// the Jump button click because `currentStem()` is a snapshot
    /// read that runs faster than the navigate Task's decode +
    /// stemPill update (~300–400 ms in test mode).
    private func waitForStem(_ expectedStem: String,
                              timeout: TimeInterval = 5,
                              file: StaticString = #file,
                              line: UInt = #line) {
        let pill = app.staticTexts["canvas.stemPill.stem"]
        let pred = NSPredicate(format: "value == %@", expectedStem)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: pill)
        let res = XCTWaiter.wait(for: [exp], timeout: timeout)
        XCTAssertEqual(res, .completed,
                       "stem pill never showed '\(expectedStem)' (current: '\(pill.value ?? "")')",
                       file: file, line: line)
    }

    private func openJumpTo() {
        pressKey("j")
        XCTAssertTrue(overlay.waitForExistence(timeout: 2),
                      "jumpTo overlay didn't appear after pressing J")
        XCTAssertTrue(queryField.waitForExistence(timeout: 2),
                      "jumpTo query field didn't appear")
        // JumpToView claims focus asynchronously
        // (`DispatchQueue.main.async { queryFocused = true }` in
        // `.onAppear`). Without an explicit click, XCUITest's
        // typeText sometimes goes to whichever responder held
        // focus before the overlay opened — the canvas — where
        // the digits/letters trigger rating shortcuts instead of
        // landing in the query field. Click the field to force
        // first-responder transition before typing.
        queryField.click()
    }

    /// Numeric query path. Index 5 in `.name`-sort order maps to
    /// DSC04178 in the bundled fixture (sorted stems:
    /// DSC00060, DSC02115, DSC04176, DSC04177, DSC04178, …).
    func test_numericIndex_jumpsToThatEntry() throws {
        _ = waitForShootLoaded()
        XCTAssertEqual(currentStem(), "DSC00060",
                       "launch should land on DSC00060")

        openJumpTo()
        // The query field arrives pre-filled with the common stem
        // prefix ("DSC0" for this fixture). Replace it with the
        // numeric query — selecting all + typing overwrites.
        queryField.typeKey("a", modifierFlags: .command)
        queryField.typeText("5")
        // `Return` from the TextField fires `.onSubmit` in
        // production, but XCUITest's synthesized `Return` doesn't
        // always trigger the SwiftUI binding — click the "Jump"
        // button directly. It's `.keyboardShortcut(.defaultAction)`-
        // bound to Return, so the user-visible behaviour is the same.
        app.buttons["Jump"].click()

        // Overlay closes synchronously; pill update is one tick.
        let deadline = Date().addingTimeInterval(2)
        while overlay.exists && Date() < deadline {
            usleep(50_000)
        }
        XCTAssertFalse(overlay.exists, "jumpTo overlay should dismiss on Return")

        waitForStem("DSC04178")
    }

    /// Exact stem path. Typing the full stem then Return jumps
    /// directly to that entry — bypasses the suggestion list.
    func test_exactStem_jumpsToThatEntry() throws {
        _ = waitForShootLoaded()

        openJumpTo()
        queryField.typeKey("a", modifierFlags: .command)
        queryField.typeText("DSC04177")
        // `Return` from the TextField fires `.onSubmit` in
        // production, but XCUITest's synthesized `Return` doesn't
        // always trigger the SwiftUI binding — click the "Jump"
        // button directly. It's `.keyboardShortcut(.defaultAction)`-
        // bound to Return, so the user-visible behaviour is the same.
        app.buttons["Jump"].click()

        let deadline = Date().addingTimeInterval(2)
        while overlay.exists && Date() < deadline {
            usleep(50_000)
        }
        waitForStem("DSC04177")
    }

    /// Escape dismisses the overlay without navigating. (The
    /// `Cancel` button is keyboardShortcut(.cancelAction); Escape
    /// also routes through `ContentView.handleKeyDown`'s keyCode-53
    /// branch but JumpToView's TextField eats its keys first.)
    func test_escape_dismissesJumpToWithoutNavigating() throws {
        _ = waitForShootLoaded()
        let before = currentStem()

        openJumpTo()
        queryField.typeKey("a", modifierFlags: .command)
        queryField.typeText("5")
        pressKey(.escape)

        let deadline = Date().addingTimeInterval(2)
        while overlay.exists && Date() < deadline {
            usleep(50_000)
        }
        XCTAssertFalse(overlay.exists,
                       "jumpTo overlay should dismiss on Escape")
        XCTAssertEqual(currentStem(), before,
                       "Escape from jumpTo must NOT change the current entry")
    }
}
