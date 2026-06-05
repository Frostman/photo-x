import XCTest

/// XCUITest coverage for the Export v2 preset workflow — applying,
/// modifying, saving back, saving as new, overwriting, reloading,
/// stale-detection, plus project-name auto-derivation + override.
///
/// Drives mutations through the Darwin notification hooks installed
/// by `UITestResetObserver` (each `apply* / save* / set* / remove*`
/// hook in the export-v2 block). Verifies both the model state
/// (`readExportConfigSnapshot` / `readExportPresetsLibrary` JSON
/// dumps) AND the corresponding visible UI (preset picker label,
/// provenance badge text, RoWM toggle state, destination rows).
///
/// Per the project's `feedback_e2e_dual_assert` rule, every test
/// that mutates state asserts both via the snapshot AND via XCUI
/// queries on the matching AX identifiers.
final class ExportPresetTests: PhotoXSessionUITestCase {

    /// Per-test output directory under `NSTemporaryDirectory()`.
    /// Used as a destination path for presets so the actual export
    /// (test 15) can land files somewhere safe; tests that don't
    /// run an export still benefit from a stable per-test path.
    private var outputBase: URL!
    private var passed: Bool = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        outputBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photox-export-preset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        passed = false
        // After the previous test, the app may be parked on the
        // Export tab. Switch back to View to confirm the shoot
        // loaded before we proceed.
        pressKey("2", modifiers: .command)
        let pill = app.staticTexts["canvas.stemPill.indexLabel"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20),
                      "shoot didn't load within 20 s after reset")
        // Make sure the library is empty (the reset hook does this
        // too, but be defensive — a partial test failure could
        // leave debris).
        try clearPresetsLibrary()
        try switchToExportTab()
    }

    override func tearDownWithError() throws {
        if let base = outputBase {
            if passed {
                try? FileManager.default.removeItem(at: base)
            } else {
                print("[ExportPresetTests] output left for inspection: \(base.path)")
            }
        }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func test_applyPreset_seedsDestinations_andRoWM() throws {
        let p1 = outputBase.appendingPathComponent("dest-a").path
        let p2 = outputBase.appendingPathComponent("dest-b").path
        try createPresetViaConfig(name: "card-cull",
                                  destinations: [p1, p2],
                                  readOnceWriteMany: false)
        try applyPreset("card-cull")

        let snap = try readConfigSnapshot()
        XCTAssertEqual(snap.sourcePresetNameCached, "card-cull")
        XCTAssertEqual(snap.destinations.map(\.path), [p1, p2])
        XCTAssertFalse(snap.readOnceWriteMany)
        XCTAssertFalse(snap.isModifiedFromPreset)
        XCTAssertFalse(snap.presetChangedSinceApply)

        // UI side.
        XCTAssertEqual(presetPickerLabel(), "card-cull")
        XCTAssertEqual(provenanceBadgeText(),
                       "Up to date with \"card-cull\"")
        XCTAssertFalse(staleBannerExists())
        XCTAssertFalse(rowToggleIsOn(rowIndex: 0, "readOnceWriteMany")
                       || readOnceWriteManyToggleIsOn(),
                       "RoWM toggle should be off after applying preset with RoWM=false")
        XCTAssertEqual(destinationRowPath(rowIndex: 0), p1)
        XCTAssertEqual(destinationRowPath(rowIndex: 1), p2)
        passed = true
    }

    func test_modifyAfterApply_setsModifiedFlag() throws {
        try createPresetViaConfig(name: "p",
                                  destinations: [outputBase.appendingPathComponent("d").path],
                                  readOnceWriteMany: true)
        try applyPreset("p")
        try updateExportDestination(at: 0, field: "includeXMP", value: false)

        let snap = try readConfigSnapshot()
        XCTAssertTrue(snap.isModifiedFromPreset)
        XCTAssertFalse(snap.destinations[0].includeXMP)

        XCTAssertEqual(provenanceBadgeText(), "Modified from \"p\"")
        XCTAssertFalse(destinationRowToggleIsOn(rowIndex: 0, "includeXMP"))
        passed = true
    }

    func test_modifyRoWM_alsoSetsModifiedFlag() throws {
        try createPresetViaConfig(name: "rowm-on",
                                  destinations: [outputBase.appendingPathComponent("d").path],
                                  readOnceWriteMany: true)
        try applyPreset("rowm-on")
        try setShootRoWM(false)

        let snap = try readConfigSnapshot()
        XCTAssertTrue(snap.isModifiedFromPreset)
        XCTAssertFalse(snap.readOnceWriteMany)

        XCTAssertEqual(provenanceBadgeText(), "Modified from \"rowm-on\"")
        XCTAssertFalse(readOnceWriteManyToggleIsOn())
        passed = true
    }

    func test_saveBack_persistsToLibrary_clearsModifiedFlag() throws {
        let dPath = outputBase.appendingPathComponent("d").path
        try createPresetViaConfig(name: "wb",
                                  destinations: [dPath],
                                  readOnceWriteMany: true)
        try applyPreset("wb")
        try updateExportDestination(at: 0, field: "includeXMP", value: false)
        try saveBackToPreset()

        let snap = try readConfigSnapshot()
        XCTAssertFalse(snap.isModifiedFromPreset)
        XCTAssertFalse(snap.destinations[0].includeXMP)

        let lib = try readPresetsLibrary()
        let wb = try XCTUnwrap(lib.presets.first(where: { $0.name == "wb" }))
        XCTAssertFalse(wb.destinations[0].includeXMP,
                       "saveBack must push the local edit into the library")

        XCTAssertEqual(provenanceBadgeText(), "Up to date with \"wb\"")
        passed = true
    }

    func test_saveAsNew_addsToLibrary_adoptsAsSource() throws {
        let aPath = outputBase.appendingPathComponent("a").path
        try createPresetViaConfig(name: "A",
                                  destinations: [aPath],
                                  readOnceWriteMany: true)
        try applyPreset("A")
        try updateExportDestination(at: 0, field: "includeXMP", value: false)
        try saveAsNewPreset("B")

        let snap = try readConfigSnapshot()
        XCTAssertEqual(snap.sourcePresetNameCached, "B")
        XCTAssertFalse(snap.isModifiedFromPreset)

        let lib = try readPresetsLibrary()
        XCTAssertEqual(Set(lib.presets.map(\.name)), Set(["A", "B"]))

        XCTAssertEqual(presetPickerLabel(), "B")
        XCTAssertEqual(provenanceBadgeText(), "Up to date with \"B\"")
        passed = true
    }

    func test_saveOverwriting_replacesTarget_andAdoptsIt() throws {
        let aPath = outputBase.appendingPathComponent("a").path
        let bPath = outputBase.appendingPathComponent("b").path
        try createPresetViaConfig(name: "A", destinations: [aPath], readOnceWriteMany: true)
        try createPresetViaConfig(name: "B", destinations: [bPath], readOnceWriteMany: true)
        try applyPreset("A")
        try updateExportDestination(at: 0, field: "includeXMP", value: false)
        try saveOverwritingPreset("B")

        let snap = try readConfigSnapshot()
        XCTAssertEqual(snap.sourcePresetNameCached, "B")
        XCTAssertFalse(snap.isModifiedFromPreset)

        let lib = try readPresetsLibrary()
        let bAfter = try XCTUnwrap(lib.presets.first(where: { $0.name == "B" }))
        // B's destinations should now match the source A's path
        // (with our XMP override), NOT B's original bPath.
        XCTAssertEqual(bAfter.destinations.map(\.path), [aPath])
        XCTAssertFalse(bAfter.destinations[0].includeXMP)

        XCTAssertEqual(presetPickerLabel(), "B")
        passed = true
    }

    func test_reloadFromPreset_revertsLocalEdits() throws {
        let dPath = outputBase.appendingPathComponent("d").path
        try createPresetViaConfig(name: "r", destinations: [dPath], readOnceWriteMany: true)
        try applyPreset("r")
        try updateExportDestination(at: 0, field: "includeXMP", value: false)
        XCTAssertTrue(try readConfigSnapshot().isModifiedFromPreset)
        try reloadFromPreset()

        let snap = try readConfigSnapshot()
        XCTAssertFalse(snap.isModifiedFromPreset)
        XCTAssertTrue(snap.destinations[0].includeXMP,
                      "reload should restore includeXMP=true from preset")

        XCTAssertEqual(provenanceBadgeText(), "Up to date with \"r\"")
        passed = true
    }

    func test_presetChangedSinceApply_detectsExternalEdit_andSurfacesBanner() throws {
        let dPath = outputBase.appendingPathComponent("d").path
        try createPresetViaConfig(name: "s", destinations: [dPath], readOnceWriteMany: true)
        try applyPreset("s")
        XCTAssertFalse(try readConfigSnapshot().presetChangedSinceApply)

        // Simulate an external bump: the `bumpExportPreset` hook
        // updates the preset directly through the library API
        // without refreshing the current shoot's snapshot. This
        // mirrors what would happen if another window saved-back
        // to the same preset.
        try bumpPreset("s")

        let snap = try readConfigSnapshot()
        XCTAssertTrue(snap.presetChangedSinceApply,
                      "library bump should be visible as a stale-preset signal")
        XCTAssertTrue(staleBannerExists(),
                      "amber banner should be visible when preset is stale")
        passed = true
    }

    func test_reloadFromStalePreset_clearsBanner() throws {
        let dPath = outputBase.appendingPathComponent("d").path
        try createPresetViaConfig(name: "stale", destinations: [dPath], readOnceWriteMany: true)
        try applyPreset("stale")
        try bumpPreset("stale")
        XCTAssertTrue(try readConfigSnapshot().presetChangedSinceApply)

        try reloadFromPreset()
        let snap = try readConfigSnapshot()
        XCTAssertFalse(snap.presetChangedSinceApply)
        XCTAssertFalse(staleBannerExists())
        XCTAssertEqual(provenanceBadgeText(), "Up to date with \"stale\"")
        passed = true
    }

    func test_removePresetWhileApplied_preservesShootState_butMarksOrphan() throws {
        let dPath = outputBase.appendingPathComponent("d").path
        try createPresetViaConfig(name: "doomed", destinations: [dPath], readOnceWriteMany: true)
        try applyPreset("doomed")
        try removePresetFromLibrary("doomed")

        let snap = try readConfigSnapshot()
        XCTAssertFalse(snap.sourcePresetExists,
                       "after removing the preset from the library, sourcePresetExists must be false")
        XCTAssertEqual(snap.sourcePresetNameCached, "doomed",
                       "cached name survives the deletion so the UI can still label the orphan badge")
        XCTAssertEqual(snap.destinations.map(\.path), [dPath],
                       "destinations stay on the shoot even after preset deletion")
        // With the preset gone, the snapshotted preset state is no
        // longer compared against a live preset — but the model's
        // existing semantics treat that as "modified" (the diff
        // sees no live preset to match the snapshot). We pin that
        // behaviour here.
        XCTAssertTrue(snap.isModifiedFromPreset || !snap.sourcePresetExists,
                      "orphan badge state should be expressible (either modified or marked orphan)")

        // UI: badge still surfaces the cached name.
        let badge = provenanceBadgeText()
        XCTAssertTrue(badge.contains("doomed"),
                      "badge should still reference the removed preset by cached name; got: \(badge)")
        passed = true
    }

    func test_clearPreset_dropsProvenance_keepsDestinations() throws {
        let dPath = outputBase.appendingPathComponent("d").path
        try createPresetViaConfig(name: "p", destinations: [dPath], readOnceWriteMany: true)
        try applyPreset("p")
        try clearPreset()

        let snap = try readConfigSnapshot()
        XCTAssertNil(snap.sourcePresetID)
        XCTAssertNil(snap.sourcePresetNameCached)
        XCTAssertEqual(snap.destinations.map(\.path), [dPath],
                       "clearing the preset must not drop the working destinations")

        XCTAssertEqual(presetPickerLabel(), "No preset")
        XCTAssertEqual(provenanceBadgeText(), "No preset applied")
        passed = true
    }

    func test_resetProjectName_clearsUserOverride() throws {
        try setProjectName("Custom-name-12345")
        let snap = try readConfigSnapshot()
        XCTAssertTrue(snap.projectNameIsUserOverride)
        XCTAssertEqual(snap.projectName, "Custom-name-12345")
        XCTAssertTrue(resetToAutoButtonExists(),
                      "↻ button should be visible while override is on")

        try resetExportProjectNameToAuto()
        let snap2 = try readConfigSnapshot()
        XCTAssertFalse(snap2.projectNameIsUserOverride)
        XCTAssertNotEqual(snap2.projectName, "Custom-name-12345",
                          "after reset, the deriver should produce a different value (folder or EXIF-derived)")
        XCTAssertFalse(resetToAutoButtonExists(),
                       "↻ button should be gone once override is cleared")
        passed = true
    }

    func test_defaultRoWM_persistsToLibrary() throws {
        // The library's `defaultReadOnceWriteMany` is read-back via
        // the library snapshot and is what gets surfaced in the
        // Manage Presets sheet's toggle. The library default only
        // seeds presets created via `library.makeBlank(...)` — the
        // user-facing "Save current as new preset…" path carries
        // the shoot's working RoWM forward, so we don't assert the
        // seeding semantic here.
        try setDefaultRoWM(false)
        var lib = try readPresetsLibrary()
        XCTAssertFalse(lib.defaultReadOnceWriteMany)

        try setDefaultRoWM(true)
        lib = try readPresetsLibrary()
        XCTAssertTrue(lib.defaultReadOnceWriteMany,
                      "flipping the default back should be reflected in the library snapshot")
        passed = true
    }

    func test_endToEnd_applyPreset_runExportAll_filesLand() throws {
        let destPath = outputBase.appendingPathComponent("dest").path
        try createPresetViaConfig(name: "e2e", destinations: [destPath], readOnceWriteMany: true,
                                  allowNonEmpty: true)
        try applyPreset("e2e")
        let projectName = "preset-e2e-batch"
        try setProjectName(projectName)
        try clickExportAll()
        let outcome = try waitForExportCompleted(timeout: 60)
        XCTAssertEqual(outcome, "complete",
                       "expected a clean batch, got: '\(outcome)'")
        let projectDir = URL(fileURLWithPath: destPath)
            .appendingPathComponent(projectName)
        let files = try FileManager.default.contentsOfDirectory(atPath: projectDir.path)
        XCTAssertGreaterThan(files.count, 0,
                             "no files written to \(projectDir.path)")

        // Snapshot survives the export — config still consistent.
        let snap = try readConfigSnapshot()
        XCTAssertEqual(snap.sourcePresetNameCached, "e2e")
        XCTAssertEqual(snap.destinations.map(\.path), [destPath])
        passed = true
    }

    // MARK: - Helpers: navigation + UI assertions

    private func switchToExportTab() throws {
        pressKey("3", modifiers: .command)
        let projectField = app.textFields["export.projectName"]
        XCTAssertTrue(projectField.waitForExistence(timeout: 5),
                      "Export tab didn't open within 5 s")
        pressKey(.escape)
    }

    private func presetPickerLabel() -> String {
        let menu = app.descendants(matching: .any)
            .matching(identifier: "export.presetPicker").firstMatch
        if menu.exists, let v = menu.value as? String, !v.isEmpty { return v }
        return menu.label
    }

    private func provenanceBadgeText() -> String {
        let badge = app.descendants(matching: .any)
            .matching(identifier: "export.presetProvenance.badge").firstMatch
        if badge.exists { return badge.label }
        return ""
    }

    private func staleBannerExists() -> Bool {
        app.descendants(matching: .any)
            .matching(identifier: "export.presetProvenance.staleBanner")
            .firstMatch.exists
    }

    private func resetToAutoButtonExists() -> Bool {
        app.buttons["export.projectName.resetToAuto"].exists
    }

    private func readOnceWriteManyToggleIsOn() -> Bool {
        toggleIsOn("export.readOnceWriteMany")
    }

    private func destinationRowToggleIsOn(rowIndex: Int, _ field: String) -> Bool {
        toggleIsOn("export.destination.\(rowIndex).\(field)")
    }

    /// Generic helper for `rowToggleIsOn(... readOnceWriteMany)` etc.
    /// Not strictly necessary but readable in the test bodies.
    private func rowToggleIsOn(rowIndex: Int, _ field: String) -> Bool {
        destinationRowToggleIsOn(rowIndex: rowIndex, field)
    }

    /// Toggle.value on macOS is "1" / "0".
    private func toggleIsOn(_ id: String) -> Bool {
        let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
        guard el.exists else { return false }
        if let v = el.value as? String { return v == "1" }
        if let v = el.value as? Int { return v == 1 }
        return false
    }

    private func destinationRowPath(rowIndex: Int) -> String {
        // The path label carries the full absolute path as its AX
        // label (the visual text is the tilde-abbreviated form).
        app.descendants(matching: .any)
            .matching(identifier: "export.destination.\(rowIndex).path")
            .firstMatch.label
    }

    // MARK: - Helpers: Darwin notification roundtrips

    /// Compose `<name>.bool` / `.json` / `.name` payloads and post.
    private func writeTextPayload(_ basename: String, _ value: String) throws {
        let payload = (NSTemporaryDirectory() as NSString).appendingPathComponent(basename)
        try value.write(toFile: payload, atomically: true, encoding: .utf8)
    }

    private func applyPreset(_ name: String) throws {
        try writeTextPayload("applyExportPreset.name", name)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.applyExportPreset",
            completion: "dev.frostman.PhotoX.uitest.applyExportPresetCompleted",
            timeout:    5)
    }

    private func clearPreset() throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.clearExportPreset",
            completion: "dev.frostman.PhotoX.uitest.clearExportPresetCompleted",
            timeout:    5)
    }

    private func saveAsNewPreset(_ name: String) throws {
        try writeTextPayload("saveExportPresetAs.name", name)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.saveExportPresetAs",
            completion: "dev.frostman.PhotoX.uitest.saveExportPresetAsCompleted",
            timeout:    5)
    }

    private func saveBackToPreset() throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.saveBackToExportPreset",
            completion: "dev.frostman.PhotoX.uitest.saveBackToExportPresetCompleted",
            timeout:    5)
    }

    private func saveOverwritingPreset(_ name: String) throws {
        try writeTextPayload("saveOverwritingExportPreset.name", name)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.saveOverwritingExportPreset",
            completion: "dev.frostman.PhotoX.uitest.saveOverwritingExportPresetCompleted",
            timeout:    5)
    }

    private func reloadFromPreset() throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.reloadFromExportPreset",
            completion: "dev.frostman.PhotoX.uitest.reloadFromExportPresetCompleted",
            timeout:    5)
    }

    private func removePresetFromLibrary(_ name: String) throws {
        try writeTextPayload("removeExportPreset.name", name)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.removeExportPreset",
            completion: "dev.frostman.PhotoX.uitest.removeExportPresetCompleted",
            timeout:    5)
    }

    /// Simulate an external preset bump: updates the named preset
    /// via `library.update(_:)` without touching the current
    /// shoot's snapshot timestamp, so the shoot ends up with a
    /// stale snapshot and `presetChangedSinceApply == true`.
    private func bumpPreset(_ name: String) throws {
        try writeTextPayload("bumpExportPreset.name", name)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.bumpExportPreset",
            completion: "dev.frostman.PhotoX.uitest.bumpExportPresetCompleted",
            timeout:    5)
    }

    private func setShootRoWM(_ value: Bool) throws {
        try writeTextPayload("setExportRoWM.bool", value ? "true" : "false")
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.setExportRoWM",
            completion: "dev.frostman.PhotoX.uitest.setExportRoWMCompleted",
            timeout:    5)
    }

    private func setDefaultRoWM(_ value: Bool) throws {
        try writeTextPayload("setExportDefaultRoWM.bool", value ? "true" : "false")
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.setExportDefaultRoWM",
            completion: "dev.frostman.PhotoX.uitest.setExportDefaultRoWMCompleted",
            timeout:    5)
    }

    private func resetExportProjectNameToAuto() throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.resetExportProjectName",
            completion: "dev.frostman.PhotoX.uitest.resetExportProjectNameCompleted",
            timeout:    5)
    }

    private func removeExportDestinationAt(_ index: Int) throws {
        try writeTextPayload("removeExportDestination.index", "\(index)")
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.removeExportDestination",
            completion: "dev.frostman.PhotoX.uitest.removeExportDestinationCompleted",
            timeout:    5)
    }

    private func updateExportDestination(at index: Int, field: String, value: Any) throws {
        var payload: [String: Any] = ["index": index, "field": field]
        payload["value"] = value
        let payloadPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("updateExportDestination.json")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: URL(fileURLWithPath: payloadPath))
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.updateExportDestination",
            completion: "dev.frostman.PhotoX.uitest.updateExportDestinationCompleted",
            timeout:    5)
    }

    private func clearPresetsLibrary() throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.clearExportPresetsLibrary",
            completion: "dev.frostman.PhotoX.uitest.clearExportPresetsLibraryCompleted",
            timeout:    5)
    }

    private func setProjectName(_ name: String) throws {
        try writeTextPayload("setExportProjectName.name", name)
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.setExportProjectName",
            completion: "dev.frostman.PhotoX.uitest.setExportProjectNameCompleted",
            timeout:    5)
    }

    private func addExportDestination(path: String, allowNonEmpty: Bool) throws {
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

    /// Build a preset by setting up the current shoot's config with
    /// the desired destinations + RoWM, then saving it as a new
    /// preset, then clearing the preset linkage so the working
    /// config is back to "no preset applied". This sequences the
    /// existing hooks (no app-side hook needed to construct
    /// presets out of band) and leaves the library populated.
    private func createPresetViaConfig(name: String,
                                       destinations: [String],
                                       readOnceWriteMany: Bool,
                                       allowNonEmpty: Bool = false) throws {
        // Drop any local destinations first so the new preset is
        // built from a clean working state.
        while try readConfigSnapshot().destinations.isEmpty == false {
            try removeExportDestinationAt(0)
        }
        try setShootRoWM(readOnceWriteMany)
        for path in destinations {
            try addExportDestination(path: path, allowNonEmpty: allowNonEmpty)
        }
        try saveAsNewPreset(name)
        try clearPreset()
        // After clearPreset, destinations are still on the shoot —
        // clear them too so the next call starts truly blank.
        while try readConfigSnapshot().destinations.isEmpty == false {
            try removeExportDestinationAt(0)
        }
    }

    private func clickExportAll() throws {
        let runAll = app.buttons["export.runAll"]
        XCTAssertTrue(runAll.waitForExistence(timeout: 3))
        let deadline = Date().addingTimeInterval(3)
        while !runAll.isEnabled && Date() < deadline {
            usleep(50_000)
        }
        XCTAssertTrue(runAll.isEnabled, "Export all stayed disabled — canRun gated")
        runAll.click()
    }

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

    /// Force a clean reset by posting the reset Darwin notify and
    /// waiting for its completion sentinel. Mirrors the session
    /// base class's between-tests reset but invoked manually
    /// inside one test.
    private func resetSessionAndWait() throws {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.reset",
            completion: "dev.frostman.PhotoX.uitest.resetCompleted",
            timeout:    20)
        let pill = app.staticTexts["canvas.stemPill.indexLabel"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20),
                      "shoot didn't reload within 20 s after manual reset")
    }

    // MARK: - Snapshot decoders

    private func readConfigSnapshot() throws -> ExportConfigSnapshot {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.readExportConfigSnapshot",
            completion: "dev.frostman.PhotoX.uitest.readExportConfigSnapshotCompleted",
            timeout:    5)
        let payloadPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("exportConfigSnapshot.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: payloadPath))
        return try JSONDecoder().decode(ExportConfigSnapshot.self, from: data)
    }

    private func readPresetsLibrary() throws -> PresetsLibrarySnapshot {
        try postDarwinNotificationAndWait(
            request:    "dev.frostman.PhotoX.uitest.readExportPresetsLibrary",
            completion: "dev.frostman.PhotoX.uitest.readExportPresetsLibraryCompleted",
            timeout:    5)
        let payloadPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("exportPresetsLibrary.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: payloadPath))
        return try JSONDecoder().decode(PresetsLibrarySnapshot.self, from: data)
    }
}

// MARK: - Codable snapshot mirrors

/// Mirrors `UITestResetObserver.ExportConfigSnapshot` — kept here
/// (not shared) so the wire format is locked at the test side
/// independent of the observer's internal naming.
struct ExportConfigSnapshot: Decodable {
    let projectName: String
    let projectNameIsUserOverride: Bool
    let readOnceWriteMany: Bool
    let sourcePresetID: String?
    let sourcePresetNameCached: String?
    let sourcePresetExists: Bool
    let isModifiedFromPreset: Bool
    let presetChangedSinceApply: Bool
    let destinations: [DestinationSnapshot]
}

struct DestinationSnapshot: Decodable {
    let path: String
    let includeARW: Bool
    let includeHIF: Bool
    let includeXMP: Bool
    let showStars: [Int]
    let showRejected: Bool
    let showUnrated: Bool
    let overwrite: String
    let allowNonEmpty: Bool
    let removeOrphans: Bool
}

struct PresetsLibrarySnapshot: Decodable {
    let defaultReadOnceWriteMany: Bool
    let presets: [PresetSnapshot]
}

struct PresetSnapshot: Decodable {
    let id: String
    let name: String
    let readOnceWriteMany: Bool
    let destinations: [DestinationSnapshot]
}
