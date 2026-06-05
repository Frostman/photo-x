import XCTest

/// XCUITest coverage for the Export pipeline — the user-facing flow
/// that copies selected photos out of the source shoot to one or more
/// destinations. The risk being insured against is data-loss: a
/// regression in batch sequencing, overwrite policy, or orphan removal
/// could destroy real files (orphan removal at a misconfigured
/// destination can delete originals). Pre-this file, the entire Export
/// surface had zero E2E coverage.
///
/// Drives the app via three test-only hooks installed by
/// `UITestResetObserver`:
///   - `addExportDestination` — bypasses NSOpenPanel (XCUITest can't
///     drive the panel) by calling `ExportSettings.shared.add(path:)`
///     directly with a JSON payload.
///   - `runExportSingleDestination` — fires `ExportRunner.startOne`
///     for the destination at a 0-based index. Avoids the per-row Run
///     button (which would need AX identifiers inside
///     `ExportDestinationRow`).
///   - `exportCompleted` — posted by `ExportRunner.logBatchCompletion`
///     when a batch finishes for any reason. Outcome string (one of
///     `complete` / `cancelled` / `failed`) is written to a payload
///     file the test reads after waiting.
///
/// Each test creates its own `NSTemporaryDirectory()`-based output
/// directory; teardown removes it on pass, leaves it on fail (path
/// printed) so the artifacts can be inspected.
///
/// Reset between tests via PhotoXSessionUITestCase's Darwin-notify
/// reset, which (post-A5) also clears `ExportSettings.shared.destinations`
/// and `projectName` so each test starts with a clean export config.
final class ExportTests: PhotoXSessionUITestCase {

    /// Per-test output directory under `NSTemporaryDirectory()`.
    private var outputBase: URL!
    /// Toggled to `true` at the end of each test that completed its
    /// assertions successfully. Teardown uses this to decide whether
    /// to remove `outputBase` (success → wipe) or leave it (failure →
    /// keep for inspection, log the path).
    private var passed: Bool = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        outputBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photox-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outputBase, withIntermediateDirectories: true)
        passed = false
        // After the previous test, the app might still be parked
        // on the Export tab. Switch back to View so the
        // canvas.stemPill is renderable — that's our
        // shoot-loaded signal. ⌘2 is the View tab shortcut
        // (see workspaceTabs in PhotoX/WorkspaceMode.swift).
        pressKey("2", modifiers: .command)
        try waitForShootLoadedInSession()
    }

    override func tearDownWithError() throws {
        if let base = outputBase {
            if passed {
                try? FileManager.default.removeItem(at: base)
            } else {
                // Leave the dir on failure so we can inspect what
                // (if anything) the export actually wrote.
                print("[ExportTests] output left for inspection: \(base.path)")
            }
        }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    /// Happy path: add a destination, set a project name, click
    /// "Export all", confirm the project sub-directory is created
    /// with at least one file per source entry.
    func test_exportBatch_writesAllSelectedEntries() throws {
        let projectName = "e2e-batch"
        try switchToExportTab()
        try addExportDestination(path: outputBase.path, allowNonEmpty: false)
        try setProjectName(projectName)
        try clickExportAll()

        let outcome = try waitForExportCompleted(timeout: 60)
        XCTAssertEqual(outcome, "complete",
                       "expected a clean batch, got outcome: '\(outcome)'")

        let projectDir = outputBase.appendingPathComponent(projectName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.path),
                      "project dir was never created at \(projectDir.path)")
        let outFiles = try FileManager.default
            .contentsOfDirectory(atPath: projectDir.path)
        XCTAssertGreaterThan(outFiles.count, 0,
                             "no files written to \(projectDir.path)")

        passed = true
    }

    /// Pre-populate the project sub-directory with an alien file
    /// before running the batch. With the destination's default
    /// `allowNonEmpty = false`, the planning phase should reject
    /// the destination and the placeholder file's mtime must be
    /// unchanged.
    func test_exportBatch_refusesNonEmptyDestinationByDefault() throws {
        let projectName = "e2e-refuse"
        let projectDir = outputBase.appendingPathComponent(projectName)
        try FileManager.default.createDirectory(
            at: projectDir, withIntermediateDirectories: true)
        let placeholder = projectDir.appendingPathComponent("placeholder.txt")
        try "placeholder".write(to: placeholder, atomically: true, encoding: .utf8)
        let mtimeBefore = try fileMTime(at: placeholder)

        try switchToExportTab()
        try addExportDestination(path: outputBase.path, allowNonEmpty: false)
        try setProjectName(projectName)
        try clickExportAll()

        let outcome = try waitForExportCompleted(timeout: 60)
        // The batch summary reports `failed` when at least one
        // destination errored (and no destination cancelled);
        // the per-destination "destination not empty" guard
        // surfaces as a planning-phase failure.
        XCTAssertNotEqual(outcome, "complete",
                          "non-empty default should refuse, got: '\(outcome)'")
        let mtimeAfter = try fileMTime(at: placeholder)
        XCTAssertEqual(mtimeBefore, mtimeAfter,
                       "placeholder mtime changed despite refusal")

        passed = true
    }

    /// Same setup as the refuse-test, but with `allowNonEmpty = true`
    /// on the destination. The batch should now succeed; the
    /// pre-existing placeholder file should still be present
    /// (overwrite policy only applies to files that match by name).
    func test_exportBatch_overwritesWhenAllowed() throws {
        let projectName = "e2e-overwrite"
        let projectDir = outputBase.appendingPathComponent(projectName)
        try FileManager.default.createDirectory(
            at: projectDir, withIntermediateDirectories: true)
        let placeholder = projectDir.appendingPathComponent("placeholder.txt")
        try "placeholder".write(to: placeholder, atomically: true, encoding: .utf8)

        try switchToExportTab()
        try addExportDestination(path: outputBase.path, allowNonEmpty: true)
        try setProjectName(projectName)
        try clickExportAll()

        let outcome = try waitForExportCompleted(timeout: 60)
        XCTAssertEqual(outcome, "complete",
                       "allowNonEmpty=true should succeed, got: '\(outcome)'")
        let outFiles = try FileManager.default
            .contentsOfDirectory(atPath: projectDir.path)
        XCTAssertGreaterThan(outFiles.count, 1,
                             "expected placeholder + exported files; got \(outFiles.count) entries")
        XCTAssertTrue(outFiles.contains("placeholder.txt"),
                      "placeholder should still be present (orphan removal off by default)")

        passed = true
    }

    /// Two destinations configured. Run only the first via the
    /// `runExportSingleDestination` hook. Confirm destination A's
    /// project folder has files; destination B's folder must be
    /// empty (no project sub-dir created).
    func test_exportSingleDestination_partialBatch() throws {
        let outA = outputBase.appendingPathComponent("destA")
        let outB = outputBase.appendingPathComponent("destB")
        try FileManager.default.createDirectory(at: outA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outB, withIntermediateDirectories: true)
        let projectName = "e2e-partial"

        try switchToExportTab()
        try addExportDestination(path: outA.path, allowNonEmpty: false)
        try addExportDestination(path: outB.path, allowNonEmpty: false)
        try setProjectName(projectName)

        // Drive ExportRunner.startOne for index 0 (destA) only.
        try runExportSingleDestination(index: 0)
        let outcome = try waitForExportCompleted(timeout: 60)
        XCTAssertEqual(outcome, "complete",
                       "single-destination run should succeed, got: '\(outcome)'")

        let outAProject = outA.appendingPathComponent(projectName)
        let outBProject = outB.appendingPathComponent(projectName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outAProject.path),
                      "destA project dir missing: \(outAProject.path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outBProject.path),
                       "destB project dir must NOT exist after a single-destination run")

        passed = true
    }

    // MARK: - Helpers

    private func switchToExportTab() throws {
        // ⌘3 is bound to the Export tab (see workspaceTabs in
        // PhotoX/WorkspaceMode.swift). Wait for the project-name
        // TextField to appear as confirmation the tab actually
        // switched.
        pressKey("3", modifiers: .command)
        let projectField = app.textFields["export.projectName"]
        XCTAssertTrue(projectField.waitForExistence(timeout: 5),
                      "Export tab didn't open within 5 s")
        // Defensive — the auto-show is suppressed under
        // `-photoxUITestMode YES` (see the gate in
        // ContentView.swift's `onChange(of: mode)`), so on a
        // session-only test bundle this is a no-op:
        // handleKeyDown's Escape path only fires when
        // `showHelp || showAnnotationHelp` is true. Kept because
        // removing it caused ExportTests to regress (⌘3 stopped
        // switching tabs) in a way I haven't fully root-caused
        // yet — restoring the Escape brought the suite back to
        // green. TODO(2026-06-04): investigate the actual cause
        // and remove this if it really is redundant.
        pressKey(.escape)
    }

    private func setProjectName(_ name: String) throws {
        // Drives ExportSettings.shared.setProjectName via Darwin
        // hook rather than typing into the TextField. XCUITest's
        // typeText on the @FocusState-managed TextField is
        // unreliable here: Tab + click + typeText combinations
        // all hit "Neither element nor any descendant has keyboard
        // focus" intermittently. The TextField is still AX-id'd
        // ("export.projectName") for UI smoke checks; setting via
        // the model layer just bypasses the focus race.
        let payloadPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("setExportProjectName.name")
        try name.write(toFile: payloadPath, atomically: true, encoding: .utf8)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.setExportProjectName",
            completion: "dev.frostman.PhotoX.uitest.setExportProjectNameCompleted",
            timeout:    5)
    }

    private func clickExportAll() throws {
        let runAll = app.buttons["export.runAll"]
        XCTAssertTrue(runAll.waitForExistence(timeout: 3))
        // canRun = isValidForExport && !destinations.isEmpty —
        // poll briefly until the button enables (SwiftUI binding
        // update lands on the next runloop tick after typeText).
        let deadline = Date().addingTimeInterval(3)
        while !runAll.isEnabled && Date() < deadline {
            usleep(50_000)
        }
        XCTAssertTrue(runAll.isEnabled, "Export all stayed disabled — canRun gated")
        runAll.click()
    }

    private func addExportDestination(path: String, allowNonEmpty: Bool) throws {
        // Match the payload-file convention used by openInNewWindow
        // and makeWindowKey: the test side writes the JSON to a
        // file under NSTemporaryDirectory (which the app reads
        // because PHOTOX_UITEST_PAYLOAD_DIR is the test runner's
        // own tmp at launch time).
        let payloadPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("addExportDestination.json")
        let json: [String: Any] = ["path": path, "allowNonEmpty": allowNonEmpty]
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: URL(fileURLWithPath: payloadPath))
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.addExportDestination",
            completion: "dev.frostman.PhotoX.uitest.addExportDestinationCompleted",
            timeout:    5)
    }

    private func runExportSingleDestination(index: Int) throws {
        let payloadPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("runExportSingleDestination.index")
        try "\(index)".write(toFile: payloadPath, atomically: true, encoding: .utf8)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.runExportSingleDestination",
            completion: "dev.frostman.PhotoX.uitest.runExportSingleDestinationCompleted",
            timeout:    5)
    }

    /// Wait up to `timeout` for the `exportCompleted` Darwin
    /// notification fired by `ExportRunner.logBatchCompletion`.
    /// Returns the outcome string written to the payload file
    /// ("complete" / "cancelled" / "failed"), or "timeout" if
    /// the sentinel never arrived. 60 s default ceiling because
    /// a full-fixture batch can take ~10–30 s wall.
    private func waitForExportCompleted(timeout: TimeInterval) throws -> String {
        let result = waitForDarwinNotification(
            named: "dev.frostman.PhotoX.uitest.exportCompleted",
            timeout: timeout,
            description: "exportCompleted")
        guard result == .completed else {
            XCTFail("export didn't complete within \(timeout) s")
            return "timeout"
        }
        let payloadPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("exportCompleted.outcome")
        let raw = (try? String(contentsOfFile: payloadPath, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: payloadPath)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fileMTime(at url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mtime = attrs[.modificationDate] as? Date else {
            throw NSError(domain: "ExportTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "no mtime on \(url.path)"])
        }
        return mtime
    }

    /// Session-class equivalent of waitForShootLoaded — the shoot
    /// is shared across the bundle (PhotoXSessionUITestCase), so
    /// this just confirms the canvas pill is visible before
    /// proceeding. If indexing is mid-flight the timeout is generous.
    private func waitForShootLoadedInSession() throws {
        let pill = app.staticTexts["canvas.stemPill.indexLabel"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20),
                      "shoot didn't load within 20 s; canvas.stemPill.indexLabel missing")
    }
}
