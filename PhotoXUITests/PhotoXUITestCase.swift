import XCTest

/// Shared HELPERS for every PhotoXUITests test. Provides:
///
/// 1. A per-test temp fixture: clones the entire repo `sample/`
///    folder into `NSTemporaryDirectory()/PhotoXUITests-<UUID>/` so
///    each test gets its own writable copy. APFS clone-on-write makes
///    this ~1–3 s even for hundreds of MB of ARW/HIF pairs.
/// 2. App launch with `PHOTOX_SAMPLE_DIR` pointing at the fixture +
///    `-photoxDisableSparkle YES -photoxUITestMode YES` launch args
///    (auto-loads the shoot, kills Sparkle's auto-check timer, skips
///    the launch-time window maximize that races XCUITest queries).
/// 3. A **no-mutation invariant** check: every non-`.xmp` file in the
///    fixture must match its initial **size + nanosecond mtime**.
///    XMP sidecars may be created or modified but must remain
///    well-formed XML. This bakes the project-wide "no
///    original-image mutation" rule into CI rather than relying
///    on code review.
///
///    Size + mtime (not SHA256) is intentional: the threat model is
///    "did the app accidentally write to a photo file", and any
///    write through Foundation / ImageIO / Metal updates mtime. A
///    SHA256 walk over the 3 GB fixture cost ~9 s per run for no
///    additional safety against realistic mutations — the only
///    failure mode (writer that preserves both size AND mtime via
///    `touch -r`) doesn't show up accidentally.
///
/// **This base class does NOT own the app/fixture lifecycle.** Two
/// concrete subclasses pick the launch model:
///
/// - `PhotoXSessionUITestCase` — launch + clone ONCE per test class,
///   reset between tests via a Darwin notification. ~3× faster
///   wall-clock; used by most tests.
/// - `PhotoXFreshLaunchUITestCase` — launch + clone per test (the
///   original behavior). Used by tests that need to observe the
///   launch cycle itself (relaunch-restores-last-entry, app-open
///   counter, PendingReopenStore consume, etc.).
///
/// On any fixture-integrity failure the temp fixture is LEFT BEHIND
/// (path logged) so it can be inspected.
class PhotoXUITestCase: XCTestCase {

    var app: XCUIApplication!
    var tempFixtureURL: URL!

    /// Snapshot of every non-`.xmp` file taken right after the clone.
    /// `assertFixtureIntegrity(against:)` re-walks the fixture and
    /// asserts each file still matches; any new non-`.xmp` filename →
    /// fail; any `.xmp` that isn't well-formed XML → fail.
    var manifest: [String: FileFingerprint] = [:]

    // MARK: fixture cloning

    /// Source-tree path of the `sample/` folder. Walks up from the
    /// test source file (`#file` is the path the test bundle was
    /// compiled against, which always points back into the repo
    /// during dev) until we find a `sample/` sibling.
    ///
    /// **`PHOTOX_FIXTURE_SOURCE_DIR` override**: when the prebuilt
    /// test bundle is shipped to a remote runner (e.g. the Tart
    /// `photox-e2e` VM driven by `just vm-e2e`), the compiled-in
    /// `#file` path is the HOST repo location, which doesn't exist
    /// in the runner's filesystem. The dispatcher injects
    /// `PHOTOX_FIXTURE_SOURCE_DIR=/Users/admin/photox-fixtures/sample`
    /// into the xctestrun's environment so this lookup short-circuits
    /// to the runner's local fixture copy without the walk.
    private static let repoSampleURL: URL = {
        if let override = ProcessInfo.processInfo.environment["PHOTOX_FIXTURE_SOURCE_DIR"] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: override, isDirectory: &isDir),
               isDir.boolValue {
                return URL(fileURLWithPath: override)
            }
        }
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

    /// Clone the repo `sample/` folder into `dest`. Only recognized
    /// pair files (ARW/HIF/HEIF/HEIC/JPG/JPEG/xmp) are copied; skip
    /// `.DS_Store` and any stray files. APFS `copyItem` is clone-on-
    /// write so this stays cheap even for hundreds of MB of ARW.
    static func cloneSampleFixture(into dest: URL) throws {
        let src = repoSampleURL
        let names = try FileManager.default.contentsOfDirectory(atPath: src.path)
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

    /// Build a freshly-numbered temp fixture URL.
    static func makeTempFixtureURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PhotoXUITests-\(UUID().uuidString)")
    }

    // MARK: integrity check

    struct FileFingerprint: Equatable {
        let size: Int64
        let mtimeNanos: Int64
    }

    /// Walk the fixture at `url` and capture a fingerprint per
    /// non-`.xmp` file. Returned map is keyed by relative path.
    static func fingerprintFixture(at url: URL) throws -> [String: FileFingerprint] {
        var out: [String: FileFingerprint] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                              includingPropertiesForKeys: [.isRegularFileKey,
                                                                            .fileSizeKey,
                                                                            .contentModificationDateKey],
                                              options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "PhotoXUITestCase", code: 1)
        }
        for case let fileURL as URL in enumerator {
            let rv = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard rv.isRegularFile == true else { continue }
            if fileURL.pathExtension == "xmp" { continue }
            let rel = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
            out[rel] = try fingerprint(of: fileURL)
        }
        return out
    }

    static func fingerprint(of url: URL) throws -> FileFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let mtimeNanos = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
        return FileFingerprint(size: size, mtimeNanos: mtimeNanos)
    }

    /// Walk the fixture at `url` and assert:
    /// 1. Every file in `manifest` still exists and matches
    ///    (size + mtime). Mismatch → XCTFail with rel path.
    /// 2. Any new non-`.xmp` file → XCTFail.
    /// 3. Every `.xmp` file is parseable as XML and contains the XMP
    ///    root namespace.
    static func assertFixtureIntegrity(at url: URL,
                                       against manifest: [String: FileFingerprint]) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                              includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else {
            XCTFail("could not enumerate \(url.path)")
            return
        }
        var seenRelPaths: Set<String> = []
        for case let fileURL as URL in enumerator {
            let rv = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard rv.isRegularFile == true else { continue }
            let rel = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
            seenRelPaths.insert(rel)

            if fileURL.pathExtension == "xmp" {
                try assertXMPWellFormed(fileURL)
                continue
            }

            guard let original = manifest[rel] else {
                XCTFail("fixture leaked: new non-xmp file '\(rel)' wasn't there at setUp")
                continue
            }
            let now = try fingerprint(of: fileURL)
            if now != original {
                XCTFail("""
                    fixture mutated: '\(rel)' changed
                      size:  \(original.size) → \(now.size)
                      mtime: \(original.mtimeNanos) → \(now.mtimeNanos)
                    """)
            }
        }
        for rel in manifest.keys where !seenRelPaths.contains(rel) {
            XCTFail("fixture missing: original file '\(rel)' was removed")
        }
    }

    private static func assertXMPWellFormed(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        do {
            let doc = try XMLDocument(data: data, options: [])
            let xml = doc.xmlString
            XCTAssertTrue(xml.contains("adobe:ns:meta/") || xml.contains("xmpmeta"),
                          "XMP sidecar \(url.lastPathComponent) doesn't look like a Lightroom XMP")
        } catch {
            XCTFail("XMP sidecar \(url.lastPathComponent) failed to parse as XML: \(error)")
        }
    }

    // MARK: app launch

    /// Capture a screenshot of the current frontmost window and
    /// attach it to the active test activity with `.keepAlways`
    /// retention so it survives in the xcresult bundle even on
    /// passing runs. Call this at "interesting moments" — after a
    /// navigation, before/after a rating mutation, etc. — and the
    /// VM-side dispatcher will pull every attachment into
    /// `build/e2e-results/<ts>/screenshots/<test>/` for review on
    /// the host.
    ///
    /// Failure auto-screenshots are captured by XCUITest for free;
    /// this helper is for the "show me what the UI looked like
    /// during this step" cases.
    @discardableResult
    func attachScreenshot(name: String) -> XCTAttachment {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return attachment
    }

    /// Promote the test runner-spawned app window to key + frontmost.
    /// `app.launch()` alone doesn't always do it — SwiftUI's
    /// `@FocusState` + `.onKeyPress` only fire when the canvas is
    /// focused, which requires the window to be key. Activates up to
    /// 60× in a 3 s budget then settles on whatever it got; tests
    /// using keyboard input should additionally click into the
    /// canvas via `waitForShootLoaded()`.
    ///
    /// 50 ms cadence (60 iterations) instead of 100 ms (30) — same
    /// total budget but finer resolution so we don't oversleep
    /// when the OS finishes promoting mid-step.
    static func promoteToKey(_ app: XCUIApplication) {
        for _ in 0 ..< 60 {  // ~3 s @ 50 ms
            app.activate()
            if app.state == .runningForeground { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let window = app.windows.firstMatch
        if window.waitForExistence(timeout: 5) {
            // Click well inside the canvas, not at center (the stem
            // pill / status pill sit roughly bottom-center). Top-left
            // quadrant of the canvas is reliably plain pixels.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).click()
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

    /// Poll until the XMP sidecar for `stem` exists AND (if
    /// `containing` is non-nil) its body contains the substring.
    /// Returns the body string on success; XCTFails on timeout.
    /// Used by RatingTests in place of a `Thread.sleep(0.5)` —
    /// XMPWriteCoordinator typically persists in ~100–200 ms; the
    /// 2 s ceiling is a flake guard.
    @discardableResult
    func waitForXMPSidecar(forPairNamed stem: String,
                            containing substring: String? = nil,
                            timeout: TimeInterval = 2,
                            file: StaticString = #file,
                            line: UInt = #line) throws -> String {
        let url = xmpSidecar(forPairNamed: stem)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path),
               let body = try? String(contentsOf: url, encoding: .utf8) {
                if let substring {
                    if body.contains(substring) { return body }
                } else {
                    return body
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("XMP sidecar for \(stem) didn't appear within \(timeout)s" +
                (substring.map { " containing \($0)" } ?? ""),
                file: file, line: line)
        return ""
    }

    /// Poll until the XMP sidecar for `stem` either doesn't
    /// exist OR exists but no longer contains `substring`.
    /// Used by undo tests to verify a previously-written
    /// attribute has been reverted — `XMPWriteCoordinator`
    /// may rewrite the file without the attribute OR leave
    /// it alone depending on the other fields present, so
    /// either shape counts as success.
    func waitForXMPSidecarWithout(forPairNamed stem: String,
                                   substring: String,
                                   timeout: TimeInterval = 2,
                                   file: StaticString = #file,
                                   line: UInt = #line) throws {
        let url = xmpSidecar(forPairNamed: stem)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: url.path) { return }
            if let body = try? String(contentsOf: url, encoding: .utf8),
               !body.contains(substring) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("XMP sidecar for \(stem) still contains \"\(substring)\" after \(timeout)s",
                file: file, line: line)
    }

    /// Snapshot the set of stems whose `.xmp` files exist in
    /// the fixture right now. Used by burst-detection helpers
    /// to compute which siblings got newly-rejected after a G
    /// keypress.
    func xmpSidecarStems() -> Set<String> {
        guard let names = try? FileManager.default
                .contentsOfDirectory(atPath: tempFixtureURL.path) else { return [] }
        var out: Set<String> = []
        for name in names where (name as NSString).pathExtension == "xmp" {
            out.insert((name as NSString).deletingPathExtension)
        }
        return out
    }

    /// After navigation, wait briefly for the displayed pair
    /// to bind to the canvas AND re-anchor focus before issuing
    /// a mutation key press. `setRating` / `setLabel` bail out
    /// when `isLoadingDisplayedPair` is true (the canvas hasn't
    /// yet shown the new entry's texture); also re-clicking
    /// the canvas defends against arrow-key navigation
    /// implicitly moving focus.
    func waitForDisplayedPairReady(timeout: TimeInterval = 3) {
        let pill = app.staticTexts["canvas.stemPill.stem"]
        _ = pill.waitForExistence(timeout: timeout)
        // Brief settle — the pill exists from launch, but the
        // currentImage / texture binding isn't accessibility-
        // exposed. ~300 ms covers the typical bind latency
        // after a nav keypress in the shared-session class.
        Thread.sleep(forTimeInterval: 0.3)
        // Re-anchor focus onto the canvas — arrow keys
        // sometimes get routed before the @FocusState rebind
        // settles.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).click()
    }

    /// Step forward N entries, settling the canvas between
    /// each press. Rapid-fire arrow keys outpace the texture
    /// binder and a subsequent mutation key (`R`, `G`, …) can
    /// fire on a still-loading pair, where it'll be silently
    /// dropped by `isLoadingDisplayedPair`.
    func navigateForward(by steps: Int) {
        let total = totalPairsFromPill()
        let startIndex = currentIndexFromPill()
        for i in 0 ..< steps {
            pressKey(.rightArrow)
            waitForPillIndex(min(startIndex + i + 1, total))
            waitForDisplayedPairReady()
        }
    }

    /// Trigger Redo via the Edit-menu item. Tests don't use
    /// the Cmd+Shift+Z keyboard shortcut because some other
    /// apps capture it system-wide and swallow the event
    /// before XCUITest delivers it. The menu click still
    /// routes through `CommandGroup(replacing: .undoRedo)` →
    /// `state.undoManager.redo()`, so the binding is
    /// exercised. The menu title is dynamic ("Redo Reject",
    /// "Redo Set Rating", …), so we match by title prefix.
    func clickRedoMenu() {
        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 2),
                      "Edit menu bar item didn't appear")
        editMenu.click()
        let pred = NSPredicate(format: "title BEGINSWITH 'Redo'")
        let item = app.menuItems.matching(pred).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 2),
                      "menu item with title starting 'Redo' didn't appear")
        item.click()
    }

    /// Block until the indexer status chip flips to `.done`.
    /// Mirrors `waitForShootLoaded` but waits for the heavier
    /// advanced-EXIF pipeline to finish too — needed by tests
    /// that depend on burst tables (`entrySequenceNumber`).
    func waitForIndexingDone(timeout: TimeInterval = 60,
                              file: StaticString = #file,
                              line: UInt = #line) {
        let chip = app.buttons["indexer.statusChip.done"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout),
                      "indexer didn't reach .done within \(timeout)s",
                      file: file, line: line)
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
    ///
    /// 20 s default: under back-to-back test runs, multiple PhotoX
    /// processes spawn in close succession and contend on disk IO
    /// (sample/ clone + UserDefaults sync); 10 s wasn't enough to
    /// stay reliably green.
    @discardableResult
    func waitForShootLoaded(timeout: TimeInterval = 20) -> Int {
        let pill = app.staticTexts["canvas.stemPill.indexLabel"]
        if !pill.waitForExistence(timeout: timeout) {
            // One more activate kick + a brief retry — sometimes the
            // OS leaves the window unfocused enough that the
            // accessibility snapshot is empty even though the app is
            // foreground per `state`.
            app.activate()
            if !pill.waitForExistence(timeout: 5) {
                XCTFail("stem pill never appeared (shoot didn't load); state=\(app.state.rawValue)")
            }
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

    /// Assert that the stem pill's `value` stays equal to `expected`
    /// for `seconds` (default 0.3 s). Used by tests that pressed a
    /// key expected to be a no-op (boundary clamp, redundant nav)
    /// — there's no state transition to predicate-wait on, so we
    /// sample at 50 ms intervals and fail on any divergence.
    ///
    /// Tighter than the old `Thread.sleep(1.0); assert(==)` pattern
    /// because the failure mode we're guarding against (delayed
    /// state change) has no plausible mechanism for arriving more
    /// than ~100 ms late.
    func assertPillStable(value expected: String,
                          forSeconds seconds: TimeInterval = 0.3,
                          file: StaticString = #file,
                          line: UInt = #line) {
        let pill = app.staticTexts["canvas.stemPill.indexLabel"]
        let intervals = max(1, Int(seconds / 0.05))
        for _ in 0 ..< intervals {
            let actual = (pill.value as? String) ?? ""
            XCTAssertEqual(actual, expected,
                           "pill changed during stability window",
                           file: file, line: line)
            Thread.sleep(forTimeInterval: 0.05)
        }
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
