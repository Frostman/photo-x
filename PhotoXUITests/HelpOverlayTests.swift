import XCTest

/// XCUITest coverage for the annotated help overlay (the per-tab
/// onboarding hints that auto-show on first entry to each
/// workspace tab in production — `PhotoX/ContentView.swift`'s
/// `onChange(of: mode, initial: true)` block).
///
/// IMPORTANT: the auto-show is NOT gated off in UI-test mode —
/// an attempt to gate it broke ⌘3 menu shortcuts for reasons
/// not yet fully understood (likely a SwiftUI view-tree /
/// `focusedSceneValue` propagation interaction). Each test in
/// this file calls `dismissAutoShownOverlay` to clear the
/// launch-time View-tab overlay before exercising the real
/// path. The session reset between tests (`resetForUITest`)
/// keeps `mode == .view`, so the auto-show only fires once per
/// bundle (`helpLastSeen.view` is bumped on first show and
/// persists in `LocalAppDefaults`).
///
/// The overlay's container has accessibility identifier
/// `help.annotationOverlay` set on a `.accessibilityElement(
/// children: .contain)` modifier (`HelpAnnotationOverlay.swift`
/// ~246), so the XCUITest probe is the `Group`-type element
/// `app.groups["help.annotationOverlay"]`.
final class HelpOverlayTests: PhotoXSessionUITestCase {

    private var overlay: XCUIElement {
        app.groups["help.annotationOverlay"]
    }

    /// Idempotent: presses Escape if the overlay is currently
    /// shown; otherwise no-op (Escape's handler at
    /// `ContentView.swift:805-813` only consumes the event when
    /// `showHelp || showAnnotationHelp` is true). Tests call
    /// this in their first line so the test body starts from a
    /// known overlay=hidden state regardless of whether the
    /// launch-time auto-show has been dismissed by a previous
    /// test in the bundle.
    private func dismissAutoShownOverlay() {
        if overlay.exists { pressKey(.escape) }
    }

    /// `?` toggles the overlay. Without a modifier it's Shift+/
    /// on the ASCII layout — driven via `pressKey("/", modifiers:
    /// .shift)` because `app.typeText("?")` requires an element
    /// with keyboard focus that XCUITest sometimes can't establish
    /// reliably on the SwiftUI canvas. The local key monitor in
    /// `ContentView.installKeyMonitor` catches it via the chars
    /// path (`chars == "?" && !mods.contains(.command)`), which
    /// `ASCIIKeyboardLayout.characters(for:)` resolves correctly
    /// from a Shift+slash physical keycode regardless of the
    /// system input source.
    func test_questionMark_opensHelpOverlay() throws {
        _ = waitForShootLoaded()
        dismissAutoShownOverlay()
        XCTAssertFalse(overlay.exists,
                       "overlay should be hidden after dismissAutoShownOverlay()")

        pressKey("/", modifiers: .shift)
        XCTAssertTrue(overlay.waitForExistence(timeout: 2),
                      "overlay didn't appear after pressing ?")

        // Toggle closed to leave the session clean. (Subsequent
        // tests in the same bundle don't rely on this — the
        // session reset between tests handles cleanup — but
        // closing is the polite thing to do.)
        pressKey("/", modifiers: .shift)
    }

    /// Open via `?`, then Escape — `ContentView.swift:805-813`
    /// keyCode 53 sets both `showHelp` and `showAnnotationHelp`
    /// to false and returns nil (consumes the event).
    func test_escape_dismissesHelpOverlay() throws {
        _ = waitForShootLoaded()
        dismissAutoShownOverlay()
        pressKey("/", modifiers: .shift)
        XCTAssertTrue(overlay.waitForExistence(timeout: 2),
                      "overlay needed to be open to test Escape dismiss")

        pressKey(.escape)

        // SwiftUI animates the overlay out over ~120 ms (the
        // `.easeInOut(duration: 0.12)` in ContentView's auto-show
        // path uses the same animation budget); poll briefly for
        // the AX element to drop.
        let deadline = Date().addingTimeInterval(2)
        while overlay.exists && Date() < deadline {
            usleep(50_000)
        }
        XCTAssertFalse(overlay.exists, "overlay didn't dismiss on Escape")
    }

    /// Open via `?`, then click on the dimmer scrim outside any
    /// annotation. The scrim is `Color.black.opacity(0.45)` with
    /// `.contentShape(Rectangle()).onTapGesture { onDismiss() }`
    /// at `HelpAnnotationOverlay.swift:191`. Clicking on a
    /// coordinate that's NOT inside one of the bracket-anchored
    /// annotation labels exercises the scrim's tap handler.
    func test_clickOutside_dismissesHelpOverlay() throws {
        _ = waitForShootLoaded()
        dismissAutoShownOverlay()
        pressKey("/", modifiers: .shift)
        XCTAssertTrue(overlay.waitForExistence(timeout: 2),
                      "overlay needed to be open to test outside-click dismiss")

        // The annotations cluster around status-bar / sidebar
        // hot zones. The top-left quadrant of the window is the
        // canvas (no annotations on the empty image area), so a
        // click there hits the dimmer. Use the overlay element
        // itself as the coordinate base so the test doesn't have
        // to guess at the window frame.
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.10))
            .click()

        let deadline = Date().addingTimeInterval(2)
        while overlay.exists && Date() < deadline {
            usleep(50_000)
        }
        XCTAssertFalse(overlay.exists,
                       "overlay didn't dismiss on click outside annotations")
    }
}
