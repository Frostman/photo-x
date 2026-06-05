import XCTest
@testable import PhotoX

@MainActor
final class ExportPresetsLibraryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "photox-presets-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: empty start

    func test_init_emptyDefaults_yieldsEmptyLibrary() {
        let lib = ExportPresetsLibrary(defaults: defaults)
        XCTAssertTrue(lib.presets.isEmpty)
        XCTAssertTrue(lib.defaultReadOnceWriteMany,
                      "default toggle on for new users")
    }

    func test_makeBlank_seedsRoWMFromDefault() {
        let lib = ExportPresetsLibrary(defaults: defaults)
        lib.defaultReadOnceWriteMany = false
        let p = lib.makeBlank(name: "x")
        XCTAssertFalse(p.readOnceWriteMany,
                       "newly minted preset inherits library's current default")
    }

    // MARK: CRUD + persistence

    func test_add_persistsAcrossInstances() {
        let lib = ExportPresetsLibrary(defaults: defaults)
        let preset = ExportPreset(name: "card-cull",
                                  destinations: [.init(path: "/Volumes/NAS/backup")],
                                  readOnceWriteMany: true)
        lib.add(preset)
        let lib2 = ExportPresetsLibrary(defaults: defaults)
        XCTAssertEqual(lib2.presets.count, 1)
        XCTAssertEqual(lib2.presets[0].name, "card-cull")
        XCTAssertEqual(lib2.presets[0].destinations[0].path, "/Volumes/NAS/backup")
    }

    func test_update_bumpsUpdatedAt() {
        let lib = ExportPresetsLibrary(defaults: defaults)
        let original = ExportPreset(name: "p", destinations: [],
                                    readOnceWriteMany: true)
        lib.add(original)
        let before = lib.presets[0].updatedAt
        // Force time to move forward by a measurable amount.
        Thread.sleep(forTimeInterval: 0.01)
        var modified = lib.presets[0]
        modified.name = "p2"
        lib.update(modified)
        XCTAssertGreaterThan(lib.presets[0].updatedAt, before,
                             "update() must bump updatedAt for stale-detection")
        XCTAssertEqual(lib.presets[0].name, "p2")
    }

    func test_remove_persists() {
        let lib = ExportPresetsLibrary(defaults: defaults)
        let p = ExportPreset(name: "x", destinations: [], readOnceWriteMany: true)
        lib.add(p)
        lib.remove(id: p.id)
        XCTAssertTrue(lib.presets.isEmpty)
        let lib2 = ExportPresetsLibrary(defaults: defaults)
        XCTAssertTrue(lib2.presets.isEmpty)
    }

    func test_defaultRoWM_persists() {
        let lib = ExportPresetsLibrary(defaults: defaults)
        lib.defaultReadOnceWriteMany = false
        let lib2 = ExportPresetsLibrary(defaults: defaults)
        XCTAssertFalse(lib2.defaultReadOnceWriteMany)
    }

    // MARK: migration from legacy singleton keys

    func test_migration_seedsDefaultPresetFromLegacyKeys() throws {
        // Simulate pre-rework UserDefaults: a destinations array,
        // a project name, and the old global readOnceWriteMany toggle.
        let legacyDest = ExportPreset.Destination(
            id: UUID(),
            path: "/Volumes/Test/photos",
            showStars: [4, 5],
            showRejected: false,
            showUnrated: false,
            includeARW: true, includeHIF: true, includeXMP: true,
            overwrite: .skipUnchangedElseOverwrite,
            allowNonEmpty: false,
            removeOrphans: false)
        let data = try JSONEncoder().encode([legacyDest])
        defaults.set(data, forKey: "export.destinations")
        defaults.set("Wedding", forKey: "export.projectName")
        defaults.set(false, forKey: "export.readOnceWriteMany")

        let lib = ExportPresetsLibrary(defaults: defaults)

        XCTAssertEqual(lib.presets.count, 1, "one 'Default' preset seeded")
        XCTAssertEqual(lib.presets[0].name, "Default")
        XCTAssertEqual(lib.presets[0].destinations.map(\.path),
                       ["/Volumes/Test/photos"])
        XCTAssertFalse(lib.presets[0].readOnceWriteMany,
                       "preset inherits legacy global RoWM value")
        XCTAssertFalse(lib.defaultReadOnceWriteMany,
                       "library default mirrors legacy global RoWM")

        // Legacy keys must be cleaned up so re-init doesn't re-migrate.
        XCTAssertNil(defaults.object(forKey: "export.destinations"))
        XCTAssertNil(defaults.object(forKey: "export.projectName"))
        XCTAssertNil(defaults.object(forKey: "export.readOnceWriteMany"))

        // Round-trip via a fresh library instance reads the new key.
        let lib2 = ExportPresetsLibrary(defaults: defaults)
        XCTAssertEqual(lib2.presets.count, 1)
        XCTAssertEqual(lib2.presets[0].name, "Default")
    }

    func test_migration_noLegacyData_leavesLibraryEmpty() {
        let lib = ExportPresetsLibrary(defaults: defaults)
        XCTAssertTrue(lib.presets.isEmpty)
        // No migration writes to the presets key when there's nothing
        // to migrate.
        XCTAssertNil(defaults.object(forKey: "export.presets"))
    }

    // MARK: Destination Codable forward-compat (formerly ExportSettingsTests)

    func test_destinationDecode_minimalJSON_fillsDefaults() throws {
        let json = #"{"path":"/tmp/x"}"#.data(using: .utf8)!
        let d = try JSONDecoder().decode(ExportPreset.Destination.self, from: json)
        XCTAssertEqual(d.path, "/tmp/x")
        XCTAssertEqual(d.showStars, [1, 2, 3, 4, 5])
        XCTAssertTrue(d.showRejected)
        XCTAssertTrue(d.includeARW)
        XCTAssertEqual(d.overwrite, .skipUnchangedElseOverwrite)
        XCTAssertFalse(d.allowNonEmpty)
        XCTAssertFalse(d.removeOrphans)
    }

    func test_destinationDecode_legacyShape_preservesId_andDefaultsNewFields() throws {
        // EXACT JSON observed in users' plists before
        // `allowNonEmpty` was added. Proves the regression that
        // wiped destinations on launch can't recur.
        let json = """
        {
            "id": "7DC8D190-C8C8-48C1-92D9-62962E9C302C",
            "path": "/private/tmp/a",
            "showStars": [5],
            "showRejected": false,
            "showUnrated": false,
            "includeARW": true,
            "includeHIF": true,
            "includeXMP": true,
            "overwrite": "skipUnchangedElseOverwrite",
            "removeOrphans": false
        }
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ExportPreset.Destination.self, from: json)
        XCTAssertEqual(d.id.uuidString, "7DC8D190-C8C8-48C1-92D9-62962E9C302C")
        XCTAssertEqual(d.path, "/private/tmp/a")
        XCTAssertEqual(d.showStars, [5])
        XCTAssertFalse(d.allowNonEmpty, "absent key → default false")
    }

    func test_destinationDecode_missingPath_throws() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(ExportPreset.Destination.self,
                                     from: "{}".data(using: .utf8)!))
    }

    // MARK: ExportPathGeometry (moved from ExportSettings)

    func test_normalize_trimsTrailingSlashes_butKeepsRoot() {
        XCTAssertEqual(ExportPathGeometry.normalize("/foo/"), "/foo")
        XCTAssertEqual(ExportPathGeometry.normalize("/foo///"), "/foo")
        XCTAssertEqual(ExportPathGeometry.normalize("/"), "/")
    }

    func test_isStrictParent_basicCases() {
        XCTAssertTrue (ExportPathGeometry.isStrictParent("/foo", of: "/foo/bar"))
        XCTAssertFalse(ExportPathGeometry.isStrictParent("/foo", of: "/foo"))
        XCTAssertFalse(ExportPathGeometry.isStrictParent("/foo", of: "/foo-bar"),
                       "common prefix without separator must not match")
        XCTAssertTrue (ExportPathGeometry.isStrictParent("/", of: "/anything"))
    }

    func test_sourceConflict_detectsAllThreeCases() {
        XCTAssertEqual(
            ExportPathGeometry.sourceConflict(destPath: "/a", sourcePath: "/a"),
            .isSource)
        XCTAssertEqual(
            ExportPathGeometry.sourceConflict(destPath: "/a/b", sourcePath: "/a"),
            .insideSource)
        XCTAssertEqual(
            ExportPathGeometry.sourceConflict(destPath: "/a", sourcePath: "/a/b"),
            .containsSource)
        XCTAssertNil(
            ExportPathGeometry.sourceConflict(destPath: "/a", sourcePath: "/b"))
    }
}
