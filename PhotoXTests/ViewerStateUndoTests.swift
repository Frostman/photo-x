import CoreGraphics
import XCTest
@testable import PhotoX

/// Coverage for Cmd+Z / Cmd+Shift+Z on rating / label / reject
/// mutations. The key contract: undo restores the exact previous
/// XMP state AND jumps selection back to the entry that was
/// mutated (even after auto-advance), with the lookup done by
/// stem so a sort/filter reorder between the action and the undo
/// doesn't misdirect.
@MainActor
final class ViewerStateUndoTests: XCTestCase {

    // MARK: - basic undo / redo

    func test_undoRating_restoresXMPAndSelection() {
        let state = makeState(stems: ["A", "B", "C"])
        state.setRating(5)                                       // rate A, auto-advance off by default
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 5)
        XCTAssertEqual(state.currentIndex, 0)
        state.undoManager.undo()
        XCTAssertNil(state.entryXMPs["A"]?.rating,
                     "undo must clear the 5-star rating")
        XCTAssertEqual(state.currentIndex, 0,
                       "selection should still be on A (no auto-advance)")
    }

    func test_undoRedoRoundTrip_returnsToOriginalState() {
        let state = makeState(stems: ["A", "B", "C"])
        state.setRating(3)
        state.undoManager.undo()
        XCTAssertNil(state.entryXMPs["A"]?.rating)
        state.undoManager.redo()
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 3)
    }

    func test_undoClearRating_restoresPreviousStars() {
        let state = makeState(stems: ["A"])
        state.setRating(5)                                       // rate to 5
        state.setRating(nil)                                     // then clear
        XCTAssertNil(state.entryXMPs["A"]?.rating)
        state.undoManager.undo()                                 // undo clear → back to 5
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 5)
    }

    func test_undoLabel_restoresPreviousLabel() {
        let state = makeState(stems: ["A"])
        state.setLabel("Red")
        XCTAssertEqual(state.entryXMPs["A"]?.label, "Red")
        state.undoManager.undo()
        XCTAssertNil(state.entryXMPs["A"]?.label)
    }

    func test_undoReject_clearsReject() {
        let state = makeState(stems: ["A"])
        state.toggleReject()                                     // rating = -1
        XCTAssertEqual(state.entryXMPs["A"]?.rating, -1)
        state.undoManager.undo()
        XCTAssertNotEqual(state.entryXMPs["A"]?.rating, -1)
    }

    // MARK: - filter auto-expand

    func test_undoToUnrated_autoEnablesShowUnrated() {
        let state = makeState(stems: ["A"])
        state.setRating(5)
        state.showUnrated = false                                // hide unrated
        state.undoManager.undo()                                 // undo: A becomes unrated again
        XCTAssertTrue(state.showUnrated,
                      "undo to unrated must auto-flip showUnrated back on")
    }

    func test_undoToStarRating_autoAddsToShowStars() {
        let state = makeState(stems: ["A"])
        state.setRating(3)
        state.setRating(nil)                                     // clear
        state.showStars.remove(3)                                // filter out 3-star
        state.undoManager.undo()                                 // undo: A becomes 3 stars
        XCTAssertTrue(state.showStars.contains(3),
                      "undo to 3-star must auto-add 3 to showStars")
    }

    func test_undoToRejected_autoEnablesShowRejected() {
        let state = makeState(stems: ["A"])
        state.toggleReject()
        state.toggleReject()                                     // clear (back to nil)
        state.showRejected = false                               // hide rejected
        state.undoManager.undo()                                 // undo: A back to rejected
        XCTAssertTrue(state.showRejected)
    }

    // MARK: - burst-reject grouping

    func test_burstReject_isOneCmdZ() {
        let state = makeState(stems: ["A1", "A2", "A3"],
                              seq: ["A1": 1, "A2": 2, "A3": 3])
        // Focus on A1; reject the rest of the burst.
        state.rejectBurstSiblings(scope: .all)
        XCTAssertEqual(state.entryXMPs["A2"]?.rating, -1)
        XCTAssertEqual(state.entryXMPs["A3"]?.rating, -1)
        state.undoManager.undo()                                 // ONE undo reverts both siblings
        XCTAssertNotEqual(state.entryXMPs["A2"]?.rating, -1)
        XCTAssertNotEqual(state.entryXMPs["A3"]?.rating, -1)
    }

    // MARK: - stem-based resolution

    func test_undoFindsCorrectEntry_evenAfterSortChange() {
        // Initial sort = .name → entries: A B C.
        // Rate B, then change sort to score-desc (puts B first
        // because of its non-zero score), then undo. The undo
        // should still target stem "B", not whatever entry is
        // currently at the captured index.
        let state = makeState(stems: ["A", "B", "C"])
        state.currentIndex = 1                                   // focus B
        state.setRating(5, for: state.shoot!.entries[1])         // use the per-stem path
        XCTAssertEqual(state.entryXMPs["B"]?.rating, 5)
        state.setSortMode(.scoreDescending)
        // B now sits at index 0 (highest score). Undo should
        // still revert B's rating, not whatever's at the old
        // index 1.
        state.undoManager.undo()
        XCTAssertNil(state.entryXMPs["B"]?.rating)
    }

    // MARK: - multi-step undo (each Cmd+Z walks back one step)

    /// User scenario: 1 → 4 → reject → 2. Each Cmd+Z must
    /// restore the immediately-previous value, in reverse.
    func test_undoMultiStepRatings_walksBackInExactOrder() {
        let state = makeState(stems: ["A"])
        state.setRating(1)
        state.setRating(4)
        state.toggleReject()                                     // → -1
        state.setRating(2)
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 2)

        // Walk back: 2 → -1 → 4 → 1 → nil.
        state.undoManager.undo()
        XCTAssertEqual(state.entryXMPs["A"]?.rating, -1,
                       "step 1: undo of setRating(2) → previous was reject")
        state.undoManager.undo()
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 4,
                       "step 2: undo of toggleReject → previous was 4")
        state.undoManager.undo()
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 1,
                       "step 3: undo of setRating(4) → previous was 1")
        state.undoManager.undo()
        XCTAssertNil(state.entryXMPs["A"]?.rating,
                     "step 4: undo of setRating(1) → previous was unrated")
    }

    /// Mixing rating + label: undo of a rating change must
    /// preserve the label (and vice versa). The captured snapshot
    /// is the WHOLE XMPSidecar, not just the field that changed.
    func test_undoRating_preservesLabelSetBeforeRating() {
        let state = makeState(stems: ["A"])
        state.setLabel("Red")
        state.setRating(5)
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 5)
        XCTAssertEqual(state.entryXMPs["A"]?.label, "Red")
        // Undo of the rating: rating goes nil, label stays "Red".
        state.undoManager.undo()
        XCTAssertNil(state.entryXMPs["A"]?.rating)
        XCTAssertEqual(state.entryXMPs["A"]?.label, "Red",
                       "label set before the undone rating must survive")
        // Next undo: label clears (back to fully empty).
        state.undoManager.undo()
        XCTAssertNil(state.entryXMPs["A"]?.label)
        XCTAssertNil(state.entryXMPs["A"]?.rating)
    }

    func test_undoLabel_preservesRatingSetBeforeLabel() {
        let state = makeState(stems: ["A"])
        state.setRating(3)
        state.setLabel("Green")
        // Undo of the label: rating stays 3, label clears.
        state.undoManager.undo()
        XCTAssertEqual(state.entryXMPs["A"]?.rating, 3,
                       "rating set before the undone label must survive")
        XCTAssertNil(state.entryXMPs["A"]?.label)
    }

    /// Burst-reject must restore each sibling's individual prior
    /// state, not blanket-clear them all. Set up three siblings
    /// with distinct priors (one rated, one labeled, one empty)
    /// then verify undo returns each to its own original value.
    func test_undoBurstReject_restoresPerSiblingPriorStates() {
        let state = makeState(stems: ["A1", "A2", "A3"],
                              seq: ["A1": 1, "A2": 2, "A3": 3])
        // Seed siblings with distinct priors via the per-stem path
        // (focus stays on A1 — these become the "previous" snapshots
        // burst-reject will capture).
        state.setRating(3,    for: state.shoot!.entries[1])      // A2 = 3 stars
        state.setLabel("Red")                                    // applies to focus = A1
        // Now focus on A1 (which has label "Red") and reject the
        // others. A2 has rating=3; A3 is empty.
        state.rejectBurstSiblings(scope: .all)
        XCTAssertEqual(state.entryXMPs["A2"]?.rating, -1)
        XCTAssertEqual(state.entryXMPs["A3"]?.rating, -1)
        // ONE undo reverts both siblings to their distinct priors.
        state.undoManager.undo()
        XCTAssertEqual(state.entryXMPs["A2"]?.rating, 3,
                       "A2 must return to its specific 3-star prior, not nil")
        XCTAssertNil(state.entryXMPs["A3"]?.rating,
                     "A3 must return to its specific empty prior")
        // The focused entry A1's label is untouched throughout
        // (rejectBurstSiblings doesn't modify the focused entry).
        XCTAssertEqual(state.entryXMPs["A1"]?.label, "Red")
    }

    // MARK: - shoot switch clears stack

    func test_shootSwitch_clearsUndoStack() {
        let state = makeState(stems: ["A", "B"])
        state.setRating(5)
        XCTAssertTrue(state.undoManager.canUndo)
        state.closeShoot()
        XCTAssertFalse(state.undoManager.canUndo,
                       "closeShoot must clear cross-shoot undo history")
    }

    // MARK: - action names

    func test_actionNames_arHumanReadable() {
        let state = makeState(stems: ["A"])
        state.setRating(5)
        XCTAssertEqual(state.undoManager.undoActionName, "Rate 5 Stars")
        state.setRating(1)
        XCTAssertEqual(state.undoManager.undoActionName, "Rate 1 Star")
        state.setRating(nil)
        XCTAssertEqual(state.undoManager.undoActionName, "Clear Rating")
        state.toggleReject()
        XCTAssertEqual(state.undoManager.undoActionName, "Reject")
        state.setLabel("Red")
        XCTAssertEqual(state.undoManager.undoActionName, "Set Label Red")
        state.setLabel(nil)
        XCTAssertEqual(state.undoManager.undoActionName, "Clear Label")
    }

    // MARK: - helpers

    private func makeState(stems: [String], seq: [String: Int] = [:]) -> ViewerState {
        // Tests share the production UserDefaults domain (see
        // AppDefaults.swift), which means whatever the dev had
        // toggled in their own settings leaks into test behaviour.
        // Force the auto-advance keys off so undo-target assertions
        // don't depend on prefs state.
        AppDefaults.shared.set(false, forKey: SettingsKey.autoAdvance)
        AppDefaults.shared.set(false, forKey: SettingsKey.autoAdvanceSidebar)

        let dir = URL(fileURLWithPath: "/tmp/photox-undo-tests-fake")
        let pairs = stems.map { stem in
            PhotoEntry(
                rawURL: dir.appendingPathComponent("\(stem).ARW"),
                previewURL: dir.appendingPathComponent("\(stem).HIF"),
                stem: stem
            )
        }
        let state = ViewerState()
        state.shoot = Shoot(folderURL: dir, entries: pairs)
        // setRating / setLabel guard against `isLoadingDisplayedPair`
        // (currentImage == nil counts as loading). Tests need a
        // sentinel image so the mutators don't early-out.
        state.currentImage = Self.stubDecodedImage()
        state.entrySequenceNumber = seq
        state.recomputeBurstIDs()
        // In production NSUndoManager wraps everything in an
        // event-driven group (one runloop iteration = one undo).
        // In sync tests the runloop never ticks so back-to-back
        // mutations would land in the same never-closing group.
        // Mutators already open their own per-action manual groups
        // (see ViewerState.setRating etc.), so we can disable the
        // event-driven wrapper and have each manual group be a
        // top-level step.
        state.undoManager.groupsByEvent = false
        return state
    }

    private static func stubDecodedImage() -> DecodedImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue
                   | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: cs, bitmapInfo: bitmap
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return DecodedImage(
            cgImage: ctx.makeImage()!,
            orientation: 1,
            decodeMS: 0,
            colorSpaceName: "sRGB"
        )
    }
}
