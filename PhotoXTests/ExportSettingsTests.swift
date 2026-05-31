import XCTest
@testable import PhotoX

@MainActor
final class ExportSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "photox-export-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: defaults / init

    func test_init_emptyDefaults_yieldsEmptyState() {
        let s = ExportSettings(defaults: defaults)
        XCTAssertEqual(s.projectName, "")
        XCTAssertTrue(s.destinations.isEmpty)
        XCTAssertTrue(s.readOnceWriteMany,
                      "read-once / write-many is the default on")
        XCTAssertFalse(s.isValidForExport)
    }

    func test_readOnceWriteMany_explicitFalse_persistsAndIsRead() {
        let s = ExportSettings(defaults: defaults)
        s.readOnceWriteMany = false
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertFalse(s2.readOnceWriteMany,
                       "explicit false must override the default")
    }

    func test_destinationDefaults_areReasonable() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/tmp/a")
        let d = s.destinations[0]
        XCTAssertEqual(d.showStars, [1, 2, 3, 4, 5])
        XCTAssertTrue(d.showRejected)
        XCTAssertTrue(d.showUnrated)
        XCTAssertTrue(d.includeARW)
        XCTAssertTrue(d.includeHIF)
        XCTAssertTrue(d.includeXMP)
        XCTAssertEqual(d.overwrite, .skipUnchangedElseOverwrite)
        XCTAssertFalse(d.removeOrphans)
    }

    // MARK: project name

    func test_projectName_setAndPersist() {
        let s = ExportSettings(defaults: defaults)
        s.setProjectName("Wedding")
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.projectName, "Wedding")
        XCTAssertTrue(s2.isValidForExport)
    }

    func test_projectName_emptyVariants_areInvalidForExport() {
        let s = ExportSettings(defaults: defaults)
        for raw in ["", "   ", "\n", "\t\t  \n"] {
            s.setProjectName(raw)
            XCTAssertFalse(s.isValidForExport, "should reject \(raw.debugDescription)")
        }
        s.setProjectName(" Trailing  ")  // whitespace around content is still valid
        XCTAssertTrue(s.isValidForExport)
    }

    // MARK: destinations CRUD

    func test_add_appendsAtEnd_setsFreshUUID() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a")
        s.add(path: "/b")
        s.add(path: "/c")
        XCTAssertEqual(s.destinations.map(\.path), ["/a", "/b", "/c"])
        let ids = Set(s.destinations.map(\.id))
        XCTAssertEqual(ids.count, 3, "every Destination should have a fresh UUID")
    }

    // MARK: add — validation against duplicate / nested paths

    func test_add_returnsOk_onFreshPath() {
        let s = ExportSettings(defaults: defaults)
        XCTAssertEqual(s.add(path: "/foo"), .ok)
        XCTAssertEqual(s.destinations.count, 1)
    }

    func test_add_rejectsDuplicatePath() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/foo")
        let result = s.add(path: "/foo")
        XCTAssertEqual(result, .duplicate)
        XCTAssertEqual(s.destinations.count, 1, "rejected add must not modify list")
    }

    func test_add_rejectsDuplicatePath_ignoringTrailingSlash() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/foo")
        XCTAssertEqual(s.add(path: "/foo/"), .duplicate)
        XCTAssertEqual(s.destinations.count, 1)
    }

    func test_add_rejectsNestedUnderExisting() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/foo")
        let result = s.add(path: "/foo/bar")
        XCTAssertEqual(result, .nestedUnder(existingPath: "/foo"))
        XCTAssertEqual(s.destinations.count, 1)
    }

    func test_add_rejectsContainingExisting() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/foo/bar")
        let result = s.add(path: "/foo")
        XCTAssertEqual(result, .containsExisting(existingPath: "/foo/bar"))
        XCTAssertEqual(s.destinations.count, 1)
    }

    func test_add_allowsSiblingsWithCommonPrefix() {
        // "/foo" must NOT be considered a parent of "/foo-bar" — the
        // strict-prefix check uses the path separator to disambiguate.
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/foo")
        XCTAssertEqual(s.add(path: "/foo-bar"), .ok)
        XCTAssertEqual(s.destinations.count, 2)
    }

    func test_add_allowsCompletelyDisjointPaths() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/Volumes/A/photos")
        XCTAssertEqual(s.add(path: "/Volumes/B/backups"), .ok)
        XCTAssertEqual(s.destinations.count, 2)
    }

    func test_normalizePath_trimsTrailingSlashes_butKeepsRoot() {
        XCTAssertEqual(ExportSettings.normalizePath("/foo/"), "/foo")
        XCTAssertEqual(ExportSettings.normalizePath("/foo///"), "/foo")
        XCTAssertEqual(ExportSettings.normalizePath("/"), "/",
                       "the root must remain '/' even after normalisation")
    }

    func test_isStrictParent_basicCases() {
        XCTAssertTrue (ExportSettings.isStrictParent("/foo", of: "/foo/bar"))
        XCTAssertTrue (ExportSettings.isStrictParent("/foo", of: "/foo/bar/baz"))
        XCTAssertFalse(ExportSettings.isStrictParent("/foo", of: "/foo"),
                       "equal paths are not a strict parent relationship")
        XCTAssertFalse(ExportSettings.isStrictParent("/foo", of: "/foo-bar"),
                       "common prefix without separator must not match")
        XCTAssertFalse(ExportSettings.isStrictParent("/foo/bar", of: "/foo"))
        XCTAssertTrue (ExportSettings.isStrictParent("/", of: "/anything"),
                       "root is a parent of everything")
    }

    func test_remove_byID_persists() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a"); s.add(path: "/b"); s.add(path: "/c")
        let middleID = s.destinations[1].id
        s.remove(id: middleID)
        XCTAssertEqual(s.destinations.map(\.path), ["/a", "/c"])
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.destinations.map(\.path), ["/a", "/c"])
    }

    func test_update_byID_mutateCallback_persists() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a")
        let id = s.destinations[0].id
        s.update(id: id) { dest in
            dest.showStars = [4, 5]
            dest.includeXMP = false
            dest.overwrite = .alwaysOverwrite
            dest.removeOrphans = true
        }
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.destinations[0].showStars, [4, 5])
        XCTAssertFalse(s2.destinations[0].includeXMP)
        XCTAssertEqual(s2.destinations[0].overwrite, .alwaysOverwrite)
        XCTAssertTrue(s2.destinations[0].removeOrphans)
    }

    func test_update_missingID_isNoOp() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a")
        s.update(id: UUID()) { $0.path = "MUTATED" }
        XCTAssertEqual(s.destinations[0].path, "/a")
    }

    // MARK: move

    func test_move_before_reorders_andPersists() {
        let s = ExportSettings(defaults: defaults)
        for c in ["a", "b", "c", "d"] { s.add(path: "/\(c)") }
        let aID = s.destinations[0].id
        let dID = s.destinations[3].id
        s.move(aID, before: dID)  // a → just before d → b, c, a, d
        XCTAssertEqual(s.destinations.map(\.path), ["/b", "/c", "/a", "/d"])

        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.destinations.map(\.path), ["/b", "/c", "/a", "/d"])

        // Move dest backwards (from index > to index): d before b
        let dID2 = s2.destinations.first(where: { $0.path == "/d" })!.id
        let bID2 = s2.destinations.first(where: { $0.path == "/b" })!.id
        s2.move(dID2, before: bID2)
        XCTAssertEqual(s2.destinations.map(\.path), ["/d", "/b", "/c", "/a"])
    }

    func test_move_sameID_isNoOp() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a"); s.add(path: "/b")
        let aID = s.destinations[0].id
        s.move(aID, before: aID)
        XCTAssertEqual(s.destinations.map(\.path), ["/a", "/b"])
    }

    func test_move_missingID_isNoOp() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/a")
        s.move(UUID(), before: UUID())
        XCTAssertEqual(s.destinations.map(\.path), ["/a"])
    }

    // MARK: readOnceWriteMany

    func test_readOnceWriteMany_persists() {
        let s = ExportSettings(defaults: defaults)
        s.readOnceWriteMany = true
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertTrue(s2.readOnceWriteMany)
    }

    // MARK: JSON round-trip

    func test_destinations_roundTripJSON_preservesAllFields() {
        let s = ExportSettings(defaults: defaults)
        s.add(path: "/x")
        let id = s.destinations[0].id
        s.update(id: id) { d in
            d.showStars = [3]
            d.showRejected = false
            d.showUnrated = false
            d.includeARW = false
            d.includeHIF = true
            d.includeXMP = true
            d.overwrite = .skipUnchangedElseNewerOnly
            d.removeOrphans = true
        }
        let s2 = ExportSettings(defaults: defaults)
        XCTAssertEqual(s2.destinations.first, s.destinations.first,
                       "Codable round-trip should be loss-free")
    }

    // MARK: forward-compatible Destination decoding

    /// Helper: decode a single `Destination` from raw JSON and
    /// return it, surfacing any error to the test. Keeps the
    /// per-test setup compact since most tests below feed a
    /// JSON literal and just check fallback behaviour.
    private func decode(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ExportSettings.Destination {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(ExportSettings.Destination.self, from: data)
    }

    func test_destinationDecode_minimalJSON_fillsEveryFieldFromDefaults() throws {
        // Only `path` is required — every other key absent.
        // The custom `init(from:)` must hand back the same
        // values the memberwise init would for omitted args.
        let d = try decode(#"{"path":"/tmp/x"}"#)
        XCTAssertEqual(d.path, "/tmp/x")
        XCTAssertEqual(d.showStars, [1, 2, 3, 4, 5])
        XCTAssertTrue(d.showRejected)
        XCTAssertTrue(d.showUnrated)
        XCTAssertTrue(d.includeARW)
        XCTAssertTrue(d.includeHIF)
        XCTAssertTrue(d.includeXMP)
        XCTAssertEqual(d.overwrite, .skipUnchangedElseOverwrite)
        XCTAssertFalse(d.allowNonEmpty, "default off — safety net for existing users")
        XCTAssertFalse(d.removeOrphans)
    }

    func test_destinationDecode_missingId_synthesizesFreshUUID() throws {
        // Two decodes of the same minimal payload should
        // produce different ids (synthesized per call).
        let a = try decode(#"{"path":"/tmp/x"}"#)
        let b = try decode(#"{"path":"/tmp/x"}"#)
        XCTAssertNotEqual(a.id, b.id,
                          "missing `id` should mint a fresh UUID per decode")
    }

    func test_destinationDecode_missingPath_throws() {
        // Path is the only field without a sensible default.
        // Decoding without it must surface as an error so a
        // corrupt persistence entry doesn't silently produce
        // a useless empty-path destination.
        XCTAssertThrowsError(try decode("{}"))
    }

    func test_destinationDecode_preNewFieldShape_decodesCleanly() throws {
        // EXACT JSON we observed in the user's plist before
        // `allowNonEmpty` was added — proves the regression
        // that wiped destinations on launch can't recur.
        let legacy = """
        {
            "id": "7DC8D190-C8C8-48C1-92D9-62962E9C302C",
            "path": "/private/tmp/untitled folder",
            "showStars": [5],
            "showRejected": false,
            "showUnrated": false,
            "includeARW": true,
            "includeHIF": true,
            "includeXMP": true,
            "overwrite": "skipUnchangedElseOverwrite",
            "removeOrphans": false
        }
        """
        let d = try decode(legacy)
        XCTAssertEqual(d.path, "/private/tmp/untitled folder")
        XCTAssertEqual(d.id.uuidString, "7DC8D190-C8C8-48C1-92D9-62962E9C302C")
        XCTAssertEqual(d.showStars, [5])
        XCTAssertFalse(d.showRejected)
        XCTAssertFalse(d.showUnrated)
        XCTAssertFalse(d.allowNonEmpty, "absent → default false")
    }

    func test_destinationDecode_preservesPresentFields_overDefaults() throws {
        // Explicit non-default values must win over the
        // fallback defaults — proves `decodeIfPresent ??`
        // only triggers when the key is genuinely absent.
        let json = """
        {
            "path": "/tmp/y",
            "showStars": [1, 5],
            "showRejected": false,
            "showUnrated": false,
            "includeARW": false,
            "includeHIF": false,
            "includeXMP": false,
            "overwrite": "alwaysOverwrite",
            "allowNonEmpty": true,
            "removeOrphans": true
        }
        """
        let d = try decode(json)
        XCTAssertEqual(d.showStars, [1, 5])
        XCTAssertFalse(d.showRejected)
        XCTAssertFalse(d.showUnrated)
        XCTAssertFalse(d.includeARW)
        XCTAssertFalse(d.includeHIF)
        XCTAssertFalse(d.includeXMP)
        XCTAssertEqual(d.overwrite, .alwaysOverwrite)
        XCTAssertTrue(d.allowNonEmpty)
        XCTAssertTrue(d.removeOrphans)
    }

    func test_destinationDecode_unknownFields_ignored() throws {
        // A future build that drops a field (or a manual plist
        // edit) shouldn't error — unknown keys are tolerated.
        let json = #"{"path":"/tmp/x","totallyMadeUpFutureField":42}"#
        let d = try decode(json)
        XCTAssertEqual(d.path, "/tmp/x")
    }

    func test_destinationDecode_oneBadEntry_doesNotWipeWholeList() throws {
        // ExportSettings.init catches `try?` on the whole
        // array decode — a single corrupt entry there would
        // historically wipe everything. JSONDecoder fails
        // the whole array on the first throw, so we can't
        // partially recover at the decoder level; this test
        // pins that behaviour so any future change that
        // wants per-entry resilience must update this test
        // first (i.e. flag the intent).
        let arrayJSON = """
        [
            {"path":"/tmp/ok"},
            {"foo":"bar"}
        ]
        """
        let data = arrayJSON.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode([ExportSettings.Destination].self, from: data),
            "today: whole array fails — change this test before introducing per-entry recovery"
        )
    }

    func test_destinationsArrayLoad_persistedShape_survivesNewField() throws {
        // End-to-end via ExportSettings.init: shove a
        // legacy-shape destinations array straight into
        // UserDefaults (as JSONEncoder would have written it)
        // and confirm `ExportSettings(defaults:)` rehydrates
        // it instead of silently dropping back to `[]`.
        let legacyArray = """
        [
            {"id":"7DC8D190-C8C8-48C1-92D9-62962E9C302C","path":"/private/tmp/a","showStars":[5],"showRejected":false,"showUnrated":false,"includeARW":true,"includeHIF":true,"includeXMP":true,"overwrite":"skipUnchangedElseOverwrite","removeOrphans":false},
            {"id":"E37EC5F0-68D5-493C-97F1-1811D79736A5","path":"/Volumes/test/photox","showStars":[5],"showRejected":false,"showUnrated":false,"includeARW":true,"includeHIF":true,"includeXMP":true,"overwrite":"skipUnchangedElseOverwrite","removeOrphans":false}
        ]
        """
        defaults.set(legacyArray.data(using: .utf8), forKey: "export.destinations")
        let s = ExportSettings(defaults: defaults)
        XCTAssertEqual(s.destinations.count, 2,
                       "legacy data without `allowNonEmpty` must round-trip cleanly")
        XCTAssertEqual(s.destinations.map(\.path),
                       ["/private/tmp/a", "/Volumes/test/photox"])
        XCTAssertFalse(s.destinations.allSatisfy(\.allowNonEmpty),
                       "absent key → default `false`, not silently `true`")
    }
}
