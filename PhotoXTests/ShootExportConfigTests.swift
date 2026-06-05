import XCTest
@testable import PhotoX

/// Per-shoot working-state semantics: preset apply / modify / save
/// flows, CRUD on destinations, user-override of project name. The
/// store is provided fresh per test against a tmpdir so persistence
/// is verified end-to-end.
@MainActor
final class ShootExportConfigTests: XCTestCase {

    private var storeDir: URL!
    private var libraryDefaults: UserDefaults!
    private var librarySuiteName: String!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photox-config-tests-\(UUID().uuidString)")
        librarySuiteName = "photox-config-lib-\(UUID().uuidString)"
        libraryDefaults = UserDefaults(suiteName: librarySuiteName)!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
        UserDefaults().removePersistentDomain(forName: librarySuiteName)
    }

    private func makeConfig(shootPath: String = "/tmp/A",
                            folderName: String = "A") ->
        (ShootExportConfig, ShootExportConfigStore, ExportPresetsLibrary)
    {
        let store = ShootExportConfigStore(directory: storeDir)
        let library = ExportPresetsLibrary(defaults: libraryDefaults)
        let config = ShootExportConfig(
            shootPath: shootPath, folderName: folderName,
            store: store, library: library)
        return (config, store, library)
    }

    // MARK: project name

    func test_init_emptyShoot_usesFolderNameAsProjectName() {
        let (config, _, _) = makeConfig(folderName: "DCIM_001")
        XCTAssertEqual(config.projectName, "DCIM_001")
        XCTAssertFalse(config.projectNameIsUserOverride)
    }

    func test_refreshAutoProjectName_setsDerivedName() {
        let (config, _, _) = makeConfig()
        let dates = [date(2026, 3, 14)]
        config.refreshAutoProjectName(dates: dates)
        XCTAssertEqual(config.projectName, "2026-March-14")
    }

    func test_setProjectNameFromUser_pinsOverride_andResistsExifFlush() {
        let (config, _, _) = makeConfig()
        config.setProjectNameFromUser("Hand-typed")
        XCTAssertTrue(config.projectNameIsUserOverride)
        config.refreshAutoProjectName(dates: [date(2026, 3, 14)])
        XCTAssertEqual(config.projectName, "Hand-typed",
                       "EXIF flush must not overwrite a user override")
    }

    func test_resetProjectNameToAuto_clearsOverride_andRederives() {
        let (config, _, _) = makeConfig()
        config.setProjectNameFromUser("Hand-typed")
        config.resetProjectNameToAuto(dates: [date(2026, 3, 14)])
        XCTAssertFalse(config.projectNameIsUserOverride)
        XCTAssertEqual(config.projectName, "2026-March-14")
    }

    // MARK: destinations CRUD

    func test_addDestination_appends_persists() {
        let (config, _, _) = makeConfig()
        XCTAssertEqual(config.addDestination(path: "/Volumes/A"), .ok)
        XCTAssertEqual(config.destinations.count, 1)
    }

    func test_addDestination_rejectsDuplicate() {
        let (config, _, _) = makeConfig()
        config.addDestination(path: "/Volumes/A")
        XCTAssertEqual(config.addDestination(path: "/Volumes/A"), .duplicate)
        XCTAssertEqual(config.destinations.count, 1)
    }

    func test_addDestination_rejectsNestedAndContaining() {
        let (config, _, _) = makeConfig()
        config.addDestination(path: "/foo")
        XCTAssertEqual(config.addDestination(path: "/foo/bar"),
                       .nestedUnder(existingPath: "/foo"))
        let (c2, _, _) = makeConfig(shootPath: "/tmp/B", folderName: "B")
        c2.addDestination(path: "/foo/bar")
        XCTAssertEqual(c2.addDestination(path: "/foo"),
                       .containsExisting(existingPath: "/foo/bar"))
    }

    // MARK: preset apply + modified diff

    func test_applyPreset_seedsDestinations_andRoWM() {
        let (config, _, library) = makeConfig()
        let preset = ExportPreset(
            name: "card-cull",
            destinations: [.init(path: "/Volumes/NAS")],
            readOnceWriteMany: false)
        library.add(preset)
        guard let applied = library.preset(id: preset.id) else { return XCTFail() }
        config.applyPreset(applied)

        XCTAssertEqual(config.destinations.map(\.path), ["/Volumes/NAS"])
        XCTAssertFalse(config.readOnceWriteMany)
        XCTAssertEqual(config.sourcePresetID, applied.id)
        XCTAssertEqual(config.sourcePresetNameCached, "card-cull")
        XCTAssertFalse(config.isModifiedFromPreset,
                       "fresh apply must not be marked modified")
    }

    func test_modifyAfterApply_flipsIsModifiedFromPreset() {
        let (config, _, library) = makeConfig()
        let preset = ExportPreset(
            name: "p", destinations: [.init(path: "/a")],
            readOnceWriteMany: true)
        library.add(preset)
        config.applyPreset(library.preset(id: preset.id)!)
        XCTAssertFalse(config.isModifiedFromPreset)
        config.setReadOnceWriteMany(false)
        XCTAssertTrue(config.isModifiedFromPreset,
                      "any field diff (incl. RoWM) flips the badge")
    }

    func test_modifyDestinations_flipsIsModifiedFromPreset() {
        let (config, _, library) = makeConfig()
        let preset = ExportPreset(
            name: "p", destinations: [.init(path: "/a")],
            readOnceWriteMany: true)
        library.add(preset)
        config.applyPreset(library.preset(id: preset.id)!)
        config.addDestination(path: "/b")
        XCTAssertTrue(config.isModifiedFromPreset)
    }

    // MARK: stale-preset detection

    func test_presetChangedSinceApply_detectsLibraryUpdate() {
        let (config, _, library) = makeConfig()
        let preset = ExportPreset(name: "p", destinations: [],
                                  readOnceWriteMany: true)
        library.add(preset)
        config.applyPreset(library.preset(id: preset.id)!)
        XCTAssertFalse(config.presetChangedSinceApply)

        Thread.sleep(forTimeInterval: 0.01)
        var modified = library.preset(id: preset.id)!
        modified.destinations.append(.init(path: "/x"))
        library.update(modified)

        XCTAssertTrue(config.presetChangedSinceApply,
                      "library bump should be visible to all shoots holding the snapshot")
    }

    // MARK: save flows

    func test_saveBackToSourcePreset_writesLocalState_clearsModified() {
        let (config, _, library) = makeConfig()
        let preset = ExportPreset(name: "p",
                                  destinations: [.init(path: "/a")],
                                  readOnceWriteMany: true)
        library.add(preset)
        config.applyPreset(library.preset(id: preset.id)!)
        config.addDestination(path: "/b")
        XCTAssertTrue(config.isModifiedFromPreset)

        config.saveBackToSourcePreset()
        XCTAssertFalse(config.isModifiedFromPreset)
        XCTAssertEqual(library.preset(id: preset.id)?.destinations.map(\.path),
                       ["/a", "/b"])
    }

    func test_saveAsNewPreset_addsToLibrary_adoptsAsSource() {
        let (config, _, library) = makeConfig()
        config.addDestination(path: "/a")
        let created = config.saveAsNewPreset(name: "fresh")
        XCTAssertEqual(library.presets.count, 1)
        XCTAssertEqual(library.presets[0].name, "fresh")
        XCTAssertEqual(config.sourcePresetID, created.id)
        XCTAssertFalse(config.isModifiedFromPreset)
    }

    func test_reloadFromSourcePreset_revertsLocalEdits() {
        let (config, _, library) = makeConfig()
        let preset = ExportPreset(name: "p",
                                  destinations: [.init(path: "/a")],
                                  readOnceWriteMany: true)
        library.add(preset)
        config.applyPreset(library.preset(id: preset.id)!)
        config.addDestination(path: "/local")
        XCTAssertTrue(config.isModifiedFromPreset)

        config.reloadFromSourcePreset()
        XCTAssertEqual(config.destinations.map(\.path), ["/a"])
        XCTAssertFalse(config.isModifiedFromPreset)
    }

    // MARK: persistence round-trip

    func test_reopen_sameShoot_restoresWorkingState() async {
        let (config, store, library) = makeConfig()
        config.setProjectNameFromUser("My Project")
        config.addDestination(path: "/a")
        // Flush the debounced save synchronously so the next
        // instance sees the data.
        config.flushPendingSave()

        let reopened = ShootExportConfig(
            shootPath: "/tmp/A", folderName: "A",
            store: store, library: library)
        XCTAssertEqual(reopened.projectName, "My Project")
        XCTAssertEqual(reopened.destinations.map(\.path), ["/a"])
        XCTAssertTrue(reopened.projectNameIsUserOverride)
    }

    // MARK: helpers

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
