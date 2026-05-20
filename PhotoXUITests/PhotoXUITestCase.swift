import CryptoKit
import XCTest

/// Shared base class for every PhotoXUITests test. Provides:
///
/// 1. A per-test temp fixture: clones the entire repo `sample/`
///    folder into `NSTemporaryDirectory()/PhotoXUITests-<UUID>/` so
///    each test gets its own writable copy. APFS clone-on-write makes
///    this ~1–3 s even for hundreds of MB of ARW/HIF pairs.
/// 2. App launch with `PHOTOX_SAMPLE_DIR` pointing at the fixture +
///    `-photoxDisableSparkle YES -photoxUITestMode YES` launch args
///    (auto-loads the shoot, kills Sparkle's auto-check timer, skips
///    the launch-time window maximize that races XCUITest queries).
/// 3. A **no-mutation invariant** check in tearDown: every non-`.xmp`
///    file in the fixture must be byte-identical to its source state
///    (size + mtime + sha256). XMP sidecars may be created or modified
///    but must remain well-formed XML. This bakes the project-wide
///    "no original-image mutation" rule into CI rather than relying
///    on code review.
///
/// On any failure the temp fixture is LEFT BEHIND (path logged) so it
/// can be inspected; otherwise it's deleted.
class PhotoXUITestCase: XCTestCase {

    var app: XCUIApplication!
    var tempFixtureURL: URL!

    /// Snapshot of every non-`.xmp` file taken right after the clone.
    /// tearDown re-walks the fixture and asserts each file still
    /// matches; any new non-`.xmp` filename → fail; any `.xmp` that
    /// isn't well-formed XML → fail.
    private var manifest: [String: FileFingerprint] = [:]
    private var teardownShouldKeepFixture = false

    // MARK: setUp / tearDown

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Clone the repo sample/ into a fresh temp dir.
        tempFixtureURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PhotoXUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempFixtureURL,
                                                 withIntermediateDirectories: true)
        try Self.cloneSampleFixture(into: tempFixtureURL)
        manifest = try fingerprintFixture()

        // Launch the app pointed at the fixture, with auto-update +
        // the launch-maximize side effect disabled.
        app = XCUIApplication()
        app.launchEnvironment["PHOTOX_SAMPLE_DIR"] = tempFixtureURL.path
        app.launchArguments = [
            "-photoxDisableSparkle", "YES",
            "-photoxUITestMode",     "YES",
        ]
        app.launch()

        // Ensure the window becomes key — SwiftUI's @FocusState +
        // .onKeyPress only fire when the canvas is focused, which
        // requires the window to be key. Just launching doesn't
        // always promote the test-runner-spawned window to key.
        app.activate()
        let window = app.windows.firstMatch
        if window.waitForExistence(timeout: 5) {
            // Click well inside the canvas, not at center (the stem
            // pill / status pill sit roughly bottom-center). Top-left
            // quadrant of the canvas is reliably plain pixels.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).click()
        }
    }

    override func tearDownWithError() throws {
        // Terminate the app first so it can't be holding open file
        // handles when we re-walk the fixture for the invariant check.
        if let app, app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }

        // The mutation-invariant check is the load-bearing one. If it
        // fails, KEEP the fixture so the failure can be inspected.
        var integrityError: Error?
        do {
            try assertFixtureIntegrity()
        } catch {
            integrityError = error
            teardownShouldKeepFixture = true
        }

        if let tempFixtureURL, !teardownShouldKeepFixture {
            try? FileManager.default.removeItem(at: tempFixtureURL)
        } else if let tempFixtureURL, teardownShouldKeepFixture {
            // Surface the path so the failing test's log makes it
            // obvious where to look.
            XCTContext.runActivity(named: "fixture kept at \(tempFixtureURL.path)") { _ in }
        }

        if let integrityError { throw integrityError }
        try super.tearDownWithError()
    }

    // MARK: fixture cloning

    /// Source-tree path of the `sample/` folder. Walks up from the
    /// test source file (`#file` is the path the test bundle was
    /// compiled against, which always points back into the repo
    /// during dev) until we find a `sample/` sibling.
    private static let repoSampleURL: URL = {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("sample")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("PhotoXUITestCase: couldn't find sample/ above \(#file)")
    }()

    private static func cloneSampleFixture(into dest: URL) throws {
        let src = repoSampleURL
        let names = try FileManager.default.contentsOfDirectory(atPath: src.path)
        // Filter to recognised pair files (case-insensitive) — skip
        // .DS_Store and any stray files. APFS copyItem is clone-on-
        // write so this stays cheap even for hundreds of MB of ARW.
        let pairExts: Set<String> = [
            "ARW",
            "HIF", "HEIF", "HEIC",
            "JPG", "JPEG",
            "xmp",
        ]
        for name in names {
            let ext = (name as NSString).pathExtension
            guard pairExts.contains(ext) else { continue }
            let from = src.appendingPathComponent(name)
            let to   = dest.appendingPathComponent(name)
            try FileManager.default.copyItem(at: from, to: to)
        }
    }

    // MARK: integrity check

    struct FileFingerprint: Equatable {
        let size: Int64
        let mtimeNanos: Int64
        let sha256: Data
    }

    private func fingerprintFixture() throws -> [String: FileFingerprint] {
        var out: [String: FileFingerprint] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: tempFixtureURL,
                                              includingPropertiesForKeys: [.isRegularFileKey,
                                                                            .fileSizeKey,
                                                                            .contentModificationDateKey],
                                              options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "PhotoXUITestCase", code: 1)
        }
        for case let url as URL in enumerator {
            let rv = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard rv.isRegularFile == true else { continue }
            if url.pathExtension == "xmp" { continue }
            let rel = url.path.replacingOccurrences(of: tempFixtureURL.path + "/", with: "")
            out[rel] = try Self.fingerprint(of: url)
        }
        return out
    }

    private static func fingerprint(of url: URL) throws -> FileFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let mtimeNanos = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)

        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunkSize = 1 << 20    // 1 MB chunks so multi-hundred-MB ARWs don't balloon memory
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return FileFingerprint(size: size,
                               mtimeNanos: mtimeNanos,
                               sha256: Data(digest))
    }

    /// Walks the fixture and asserts:
    /// 1. Every file recorded in `manifest` still exists and matches
    ///    (size, mtime, sha256). Mismatch → fail with rel path.
    /// 2. Any new non-`.xmp` file → fail.
    /// 3. Every `.xmp` file (pre-existing or new) is parseable as XML
    ///    and contains the XMP root namespace.
    private func assertFixtureIntegrity() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: tempFixtureURL,
                                              includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else {
            XCTFail("could not enumerate \(tempFixtureURL.path)")
            return
        }
        var seenRelPaths: Set<String> = []
        for case let url as URL in enumerator {
            let rv = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard rv.isRegularFile == true else { continue }
            let rel = url.path.replacingOccurrences(of: tempFixtureURL.path + "/", with: "")
            seenRelPaths.insert(rel)

            if url.pathExtension == "xmp" {
                try assertXMPWellFormed(url)
                continue
            }

            guard let original = manifest[rel] else {
                XCTFail("fixture leaked: new non-xmp file '\(rel)' wasn't there at setUp")
                continue
            }
            let now = try Self.fingerprint(of: url)
            if now != original {
                XCTFail("""
                    fixture mutated: '\(rel)' changed
                      size:   \(original.size) → \(now.size)
                      mtime:  \(original.mtimeNanos) → \(now.mtimeNanos)
                      sha256: \(original.sha256.map { String(format: "%02x", $0) }.joined()) → \(now.sha256.map { String(format: "%02x", $0) }.joined())
                    """)
            }
        }
        // Any file the manifest had but we didn't see now → fail
        // (something deleted the original).
        for rel in manifest.keys where !seenRelPaths.contains(rel) {
            XCTFail("fixture missing: original file '\(rel)' was removed")
        }
    }

    private func assertXMPWellFormed(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        do {
            let doc = try XMLDocument(data: data, options: [])
            // A Lightroom-compatible sidecar is rooted at <x:xmpmeta>
            // (namespace `adobe:ns:meta/`). Anything else and the
            // file isn't useful as an XMP sidecar.
            let xml = doc.xmlString
            XCTAssertTrue(xml.contains("adobe:ns:meta/") || xml.contains("xmpmeta"),
                          "XMP sidecar \(url.lastPathComponent) doesn't look like a Lightroom XMP")
        } catch {
            XCTFail("XMP sidecar \(url.lastPathComponent) failed to parse as XML: \(error)")
        }
    }

    // MARK: helpers used by tests

    /// Stems of all entries in the fixture, sorted. Mirrors
    /// `EntryFinder.entries(in:)` exactly: a stem counts if it has
    /// any preview (HIF/HEIF/HEIC or JPG/JPEG) — ARW alone is
    /// dropped. The associated RAW is allowed but not required.
    func sortedPairStems() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: tempFixtureURL.path)
        let heifExts: Set<String> = ["HIF", "HEIF", "HEIC", "hif", "heif", "heic"]
        let jpgExts:  Set<String> = ["JPG", "JPEG", "jpg", "jpeg"]
        let previews = names
            .filter { heifExts.contains(($0 as NSString).pathExtension)
                  || jpgExts .contains(($0 as NSString).pathExtension) }
            .map    { ($0 as NSString).deletingPathExtension }
        return Array(Set(previews)).sorted()
    }

    /// URL of the XMP sidecar for a pair named `<stem>` in the
    /// fixture (may or may not exist on disk).
    func xmpSidecar(forPairNamed stem: String) -> URL {
        tempFixtureURL.appendingPathComponent("\(stem).xmp")
    }

    /// Type a single keyboard shortcut at the main window. Wraps the
    /// XCUIElement API in something concise. `@nonobjc` on both so
    /// the two overloads don't collide on the same Obj-C selector.
    @nonobjc func pressKey(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags = []) {
        // Target the main window so XCUITest brings it forward
        // before posting key events. `app.typeKey` on macOS sometimes
        // drops events when there's no explicit focus target.
        app.windows.firstMatch.typeKey(key, modifierFlags: modifiers)
    }

    @nonobjc func pressKey(_ key: String, modifiers: XCUIElement.KeyModifierFlags = []) {
        app.windows.firstMatch.typeKey(key, modifierFlags: modifiers)
    }

    /// Type literal text into the focused canvas. Use when SwiftUI
    /// `.onKeyPress(keys: ["…"])` registrations don't fire for
    /// `typeKey` events (observed for plain ASCII digits on macOS).
    @nonobjc func typeText(_ text: String) {
        app.windows.firstMatch.typeText(text)
    }

    /// Wait for the shoot to finish initial load — observed via the
    /// `canvas.stemPill.indexLabel` element appearing. Returns the
    /// total pair count parsed from the "N/M" label, or fails.
    @discardableResult
    func waitForShootLoaded(timeout: TimeInterval = 10) -> Int {
        let pill = app.staticTexts["canvas.stemPill.indexLabel"]
        if !pill.waitForExistence(timeout: timeout) {
            XCTFail("stem pill never appeared (shoot didn't load); state=\(app.state.rawValue)")
        }
        // Now that the shoot is loaded, click into the canvas to
        // confirm the .focusable() view takes @FocusState focus.
        // .onAppear-driven focus can be raced by the test runner
        // bringing itself forward during launch.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).click()
        return totalPairsFromPill()
    }

    /// "N/M" label parsing helpers.
    func currentIndexFromPill() -> Int {
        parsePillIndex().index
    }

    func totalPairsFromPill() -> Int {
        parsePillIndex().total
    }

    private func parsePillIndex() -> (index: Int, total: Int) {
        let raw = (app.staticTexts["canvas.stemPill.indexLabel"].value as? String) ?? ""
        let parts = raw.split(separator: "/").map(String.init)
        guard parts.count == 2,
              let i = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let t = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            XCTFail("could not parse stem pill index label '\(raw)'")
            return (0, 0)
        }
        return (i, t)
    }

    /// Block until the pill shows `expected/total`. Required after
    /// every keystroke — XCUITest's accessibility snapshot cache
    /// doesn't auto-refresh on SwiftUI value-only updates, so
    /// `currentIndexFromPill()` immediately after a key press will
    /// return the stale prior value.
    func waitForPillIndex(_ expected: Int, total: Int? = nil, timeout: TimeInterval = 3) {
        let pill = app.staticTexts["canvas.stemPill.indexLabel"]
        let pred: NSPredicate
        if let total {
            pred = NSPredicate(format: "value == %@", "\(expected)/\(total)")
        } else {
            pred = NSPredicate(format: "value BEGINSWITH %@", "\(expected)/")
        }
        let exp = XCTNSPredicateExpectation(predicate: pred, object: pill)
        let res = XCTWaiter.wait(for: [exp], timeout: timeout)
        XCTAssertEqual(res, .completed,
                       "pill index didn't reach \(expected) within \(timeout)s (current: '\(pill.value ?? "")')")
    }

    /// The stem of the currently-displayed pair (e.g. "DSC04207").
    func currentStem() -> String {
        (app.staticTexts["canvas.stemPill.stem"].value as? String) ?? ""
    }

    /// EXIF row value lookup. Returns nil if the row isn't currently
    /// shown (e.g. ISO row hidden for an image without ISO).
    func currentEXIFValue(_ key: String) -> String? {
        let el = app.staticTexts["exif.row.\(key).value"]
        guard el.exists else { return nil }
        return (el.value as? String) ?? el.label
    }
}
