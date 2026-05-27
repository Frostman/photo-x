import XCTest

/// End-to-end coverage for undo / redo wired through SwiftUI's
/// `CommandGroup(replacing: .undoRedo)` in `PhotoXApp.swift`.
///
/// The undo *behavior* is exhaustively covered in-process by
/// `ViewerStateUndoTests.swift`. These tests prove the UI path:
/// real keyboard events route to the app, the Edit-menu items
/// fire `undoManager.undo()` / `.redo()`, and the resulting
/// state changes round-trip through `XMPWriteCoordinator` to
/// real files on disk.
///
/// Undo uses the Cmd+Z keyboard shortcut (proves the actual
/// user-facing binding works end-to-end). Redo uses the
/// Edit-menu item click instead of Cmd+Shift+Z, because some
/// other apps can intercept Cmd+Shift+Z system-wide and
/// swallow the test's keyboard event before XCUITest delivers
/// it to PhotoX. The menu click still routes through
/// `CommandGroup(replacing: .undoRedo)` → `state.undoManager
/// .redo()`, so the binding is exercised; just not the
/// keystroke.
///
/// XMP fragments use the **element** form PhotoX writes —
/// `<xmp:Rating>5</xmp:Rating>`, not `xmp:Rating="5"`.
///
/// Each test uses a different entry so its on-disk XMP changes
/// don't influence sibling tests. To stay independent of the
/// fixture's pre-populated XMP state, each test snapshots the
/// SEMANTIC state (`rating` + `label`) of the XMP before
/// mutating, and asserts the snapshot is restored after undo.
/// We don't compare raw file bodies — pre-existing Lightroom-
/// written sidecars have different whitespace + attribute
/// ordering than PhotoX's canonical writes, so an undo round-
/// trip produces a semantically-equivalent file with a
/// different byte body.
final class UndoTests: PhotoXSessionUITestCase {

    // MARK: - 1. Single-action undo round-trips XMP

    func test_undo_revertsRejectXMP() throws {
        waitForShootLoaded()
        navigateForward(by: 1)               // entry 2
        let stem = currentStem()
        let before = currentXMP(forPairNamed: stem)

        pressKey("R")
        try waitForXMP(forPairNamed: stem, toDifferFrom: before)

        pressKey("z", modifiers: .command)
        try waitForXMP(forPairNamed: stem, toMatch: before)
    }

    // MARK: - 2. Undo + redo round-trip (via Edit menu)

    func test_undoThenRedo_roundTrip() throws {
        waitForShootLoaded()
        navigateForward(by: 2)               // entry 3
        let stem = currentStem()
        let before = currentXMP(forPairNamed: stem)

        pressKey("R")
        let afterR = try waitForXMP(forPairNamed: stem,
                                     toDifferFrom: before)

        pressKey("z", modifiers: .command)
        try waitForXMP(forPairNamed: stem, toMatch: before)

        clickRedoMenu()
        try waitForXMP(forPairNamed: stem, toMatch: afterR)
    }

    // MARK: - 3. Multi-step undo + redo on a single entry

    func test_multiStepUndoRedo_walksBackEachAction() throws {
        waitForShootLoaded()
        navigateForward(by: 3)               // entry 4
        let stem = currentStem()
        let s0 = currentXMP(forPairNamed: stem)

        // Three layered mutations: reject → green label → 5-star.
        // Snapshot the semantic XMP state after each so undo
        // can be verified against the exact between-step state.
        pressKey("R")
        let s1 = try waitForXMP(forPairNamed: stem,
                                 toDifferFrom: s0)
        pressKey("3", modifiers: .shift)             // ⇧3 = #
        let s2 = try waitForXMP(forPairNamed: stem,
                                 toDifferFrom: s1)
        // Digit keys aren't reliable in XCUITest (per
        // RatingTests' class-doc on the double-fire bug); use
        // the sidebar star button instead.
        app.buttons["decisions.star.5"].click()
        let s3 = try waitForXMP(forPairNamed: stem,
                                 toDifferFrom: s2)

        // Walk back through every step
        pressKey("z", modifiers: .command)
        try waitForXMP(forPairNamed: stem, toMatch: s2)
        pressKey("z", modifiers: .command)
        try waitForXMP(forPairNamed: stem, toMatch: s1)
        pressKey("z", modifiers: .command)
        try waitForXMP(forPairNamed: stem, toMatch: s0)

        // Redo back to s3
        clickRedoMenu()
        try waitForXMP(forPairNamed: stem, toMatch: s1)
        clickRedoMenu()
        try waitForXMP(forPairNamed: stem, toMatch: s2)
        clickRedoMenu()
        try waitForXMP(forPairNamed: stem, toMatch: s3)
    }

    // MARK: - 4. Score + burst-reject undo ordering

    /// The user-flagged regression scenario: rate a burst
    /// keeper, press G to reject siblings, Cmd+Z (via menu)
    /// undoes the burst (siblings revert, keeper score
    /// survives), Cmd+Z again undoes the score.
    ///
    /// Requires the fixture to actually have a burst (entries
    /// with non-1 Sony:SequenceNumber). `findBurstKeeper`
    /// discovers one at runtime; XCTSkips if none in the
    /// first 20 scanned entries.
    func test_scoreAndBurstReject_undoOrder() throws {
        waitForShootLoaded()
        waitForIndexingDone()   // burst tables depend on advanced-EXIF

        guard let (keeperStem, siblingStems) = try findBurstKeeper(maxScan: 20) else {
            throw XCTSkip("sample fixture has no detectable burst within first 20 entries")
        }

        // Snapshot the keeper + each sibling so we can verify
        // exact semantic reversal regardless of pre-existing
        // XMP state.
        let keeperBefore   = currentXMP(forPairNamed: keeperStem)
        let siblingsBefore = Dictionary(uniqueKeysWithValues:
            siblingStems.map { ($0, currentXMP(forPairNamed: $0)) })

        // Set 4-star rating via sidebar (digit keys unreliable)
        app.buttons["decisions.star.4"].click()
        let keeperAfterScore = try waitForXMP(forPairNamed: keeperStem,
                                               toDifferFrom: keeperBefore)

        // Press G — reject all siblings
        pressKey("G")
        for sib in siblingStems {
            try waitForXMP(forPairNamed: sib,
                            toDifferFrom: siblingsBefore[sib]
                                ?? XMPSemantic())
        }

        // Navigate away — keeper-jump assertion below verifies
        // undo navigates BACK. Use `navigateForward` (not bare
        // `pressKey(.rightArrow)`) so the canvas finishes
        // settling after the G keypress before consuming the
        // arrow.
        navigateForward(by: 1)
        XCTAssertNotEqual(currentStem(), keeperStem,
                          "should have moved off the keeper before undo")

        // First undo: reverts the burst-reject group.
        //   - siblings each return to their snapshotted state
        //   - keeper's 4-star score is INTACT
        //   - selection jumps back to the keeper
        pressKey("z", modifiers: .command)
        let pred = NSPredicate(format: "value == %@", keeperStem)
        let stemElem = app.staticTexts["canvas.stemPill.stem"]
        let exp = XCTNSPredicateExpectation(predicate: pred, object: stemElem)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "burst-reject undo must jump back to keeper \(keeperStem); got \(currentStem())")
        for sib in siblingStems {
            try waitForXMP(forPairNamed: sib,
                            toMatch: siblingsBefore[sib] ?? XMPSemantic())
        }
        XCTAssertEqual(currentXMP(forPairNamed: keeperStem),
                       keeperAfterScore,
                       "keeper's 4-star score must survive the burst-reject undo")

        // Second undo: reverts the score → keeper back to original.
        pressKey("z", modifiers: .command)
        try waitForXMP(forPairNamed: keeperStem, toMatch: keeperBefore)
    }

    // MARK: - private helpers

    /// Semantic view of an XMP sidecar restricted to the
    /// fields these tests mutate. Comparing semantics (vs.
    /// raw file bytes) is necessary because pre-existing
    /// Lightroom-canonical sidecars get rewritten in PhotoX-
    /// canonical form on first touch — the undo round-trip
    /// restores the SAME (rating, label) but with different
    /// whitespace + attribute ordering.
    struct XMPSemantic: Equatable {
        var rating: Int?
        var label: String?
    }

    private func currentXMP(forPairNamed stem: String) -> XMPSemantic {
        let url = xmpSidecar(forPairNamed: stem)
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            return XMPSemantic()
        }
        var sem = XMPSemantic()
        sem.rating = extractInt(from: body, tag: "xmp:Rating")
        sem.label  = extractString(from: body, tag: "xmp:Label")
        return sem
    }

    private func extractString(from body: String, tag: String) -> String? {
        // Element form: <xmp:Tag>value</xmp:Tag>
        let elemPattern = "<\(tag)>([^<]+)</\(tag)>"
        if let r = body.range(of: elemPattern, options: .regularExpression) {
            let inner = body[r]
                .replacingOccurrences(of: "<\(tag)>", with: "")
                .replacingOccurrences(of: "</\(tag)>", with: "")
            return inner
        }
        // Attribute form: <… xmp:Tag="value" …>
        let attrPattern = "\(tag)=\"([^\"]*)\""
        if let r = body.range(of: attrPattern, options: .regularExpression) {
            let chunk = body[r]
                .replacingOccurrences(of: "\(tag)=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
            return chunk
        }
        return nil
    }

    private func extractInt(from body: String, tag: String) -> Int? {
        extractString(from: body, tag: tag).flatMap(Int.init)
    }

    /// Poll until the XMP for `stem` differs from `before`.
    /// Returns the new state for chaining.
    @discardableResult
    private func waitForXMP(forPairNamed stem: String,
                             toDifferFrom before: XMPSemantic,
                             timeout: TimeInterval = 3,
                             file: StaticString = #file,
                             line: UInt = #line) throws -> XMPSemantic {
        let deadline = Date().addingTimeInterval(timeout)
        var last = before
        while Date() < deadline {
            last = currentXMP(forPairNamed: stem)
            if last != before { return last }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("XMP for \(stem) didn't change within \(timeout)s (still \(before))",
                file: file, line: line)
        return last
    }

    /// Poll until the XMP for `stem` matches `target`.
    private func waitForXMP(forPairNamed stem: String,
                             toMatch target: XMPSemantic,
                             timeout: TimeInterval = 3,
                             file: StaticString = #file,
                             line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = XMPSemantic()
        while Date() < deadline {
            last = currentXMP(forPairNamed: stem)
            if last == target { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("XMP for \(stem) didn't reach \(target) within \(timeout)s (last: \(last))",
                file: file, line: line)
    }

    /// Walk forward through entries pressing G on each, looking
    /// for one whose burst-reject touches OTHER entries' XMP
    /// files (= it's in a burst with detectable siblings).
    /// Undoes the discovery G before returning so the test
    /// proper starts with a clean undo stack and sibling files
    /// back to their pre-discovery state.
    /// Returns nil if no burst is found within `maxScan`
    /// entries — caller XCTSkips.
    private func findBurstKeeper(maxScan: Int) throws
        -> (keeper: String, siblings: [String])?
    {
        // Snapshot every stem's XMP semantics once up front
        // (siblings that don't have a pre-existing XMP appear
        // here as the default `XMPSemantic()` — rating=nil,
        // label=nil — and the inequality check works the same).
        var beforeAll: [String: XMPSemantic] = [:]
        for stem in try sortedPairStems() {
            beforeAll[stem] = currentXMP(forPairNamed: stem)
        }

        for scan in 0 ..< maxScan {
            waitForDisplayedPairReady()
            let candidateStem = currentStem()
            pressKey("G")
            Thread.sleep(forTimeInterval: 0.5)
            // Any sibling whose semantic state changed = burst
            // member. Skip the keeper itself.
            var touched: [String] = []
            for stem in try sortedPairStems() where stem != candidateStem {
                if currentXMP(forPairNamed: stem) != beforeAll[stem] {
                    touched.append(stem)
                }
            }
            if !touched.isEmpty {
                // Found one. Undo the discovery G; wait until
                // ONE of the touched siblings' XMP reverts.
                pressKey("z", modifiers: .command)
                if let sib = touched.first {
                    try waitForXMP(
                        forPairNamed: sib,
                        toMatch: beforeAll[sib] ?? XMPSemantic())
                }
                return (candidateStem, touched.sorted())
            }
            if scan + 1 >= maxScan { break }
            pressKey(.rightArrow)
        }
        return nil
    }
}
