import AppKit
import Carbon.HIToolbox
import XCTest
@testable import PhotoX

@MainActor
final class ASCIIKeyboardLayoutTests: XCTestCase {
    /// Synthesises a key-down NSEvent for the given virtual keyCode + modifier
    /// flags. The character payload is left empty — `ASCIIKeyboardLayout`
    /// ignores it in favour of the keyCode + flags, which is the whole point
    /// of the helper.
    private func keyDown(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }

    func test_letter_unshifted_maps_to_lowercase() {
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_R)), "r")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_X)), "x")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_J)), "j")
    }

    func test_letter_shifted_maps_to_uppercase() {
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_R, .shift)), "R")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_X, .shift)), "X")
    }

    /// The Russian-mode showstopper: Shift+3 produces `№` natively, but our
    /// helper must report the US-layout character (`#`) so the colour-label
    /// shortcut keeps firing.
    func test_shift_digits_map_to_us_punctuation() {
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_1, .shift)), "!")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_2, .shift)), "@")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_3, .shift)), "#")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_4, .shift)), "$")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_5, .shift)), "%")
    }

    func test_brackets_and_question_mark() {
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_LeftBracket)), "[")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_RightBracket)), "]")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_Slash, .shift)), "?")
    }

    func test_digits_unshifted() {
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_0)), "0")
        XCTAssertEqual(ASCIIKeyboardLayout.characters(for: keyDown(kVK_ANSI_5)), "5")
    }
}
