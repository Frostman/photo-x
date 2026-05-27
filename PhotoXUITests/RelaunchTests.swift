import XCTest

/// Tests that genuinely need a fresh app process per test — i.e.
/// they test the launch lifecycle itself. Subclasses
/// `PhotoXFreshLaunchUITestCase` (per-test launch) rather than
/// `PhotoXSessionUITestCase` (shared session), so each test gets
/// its own `XCUIApplication` and fresh fixture clone.
///
/// As the relaunch-driven feature set grows (PendingReopenStore
/// consume, app-open counter assertions, first-window behaviour,
/// etc.) more tests land in this file.
final class RelaunchTests: PhotoXFreshLaunchUITestCase {

    /// Rate (well, navigate to) an entry deep in the shoot, terminate
    /// the app, relaunch it pointing at the same `PHOTOX_SAMPLE_DIR`,
    /// and verify the canvas resumes on the same stem.
    ///
    /// Exercises the full reopen path:
    /// `FavoriteShoots.lastEntry(for:)` ← `captureLastEntryToStores`
    /// (called at `applicationWillTerminate`) → `PhotoXApp.bootstrap`'s
    /// "savedStem first" preference.
    func test_relaunch_restoresLastEntry() throws {
        let total = waitForShootLoaded()
        XCTAssertGreaterThan(total, 10, "fixture too small to exercise mid-shoot resume")

        // Walk 10 frames in. This places us deep enough that the
        // restore can't accidentally pass by landing on the first
        // entry (which would happen if `savedStem` lookup failed).
        for _ in 0 ..< 10 {
            pressKey(.rightArrow)
        }
        waitForPillIndex(11)
        let restoreStem = currentStem()
        XCTAssertFalse(restoreStem.isEmpty, "currentStem unexpectedly empty before quit")

        // XCUIApplication.terminate() doesn't invoke
        // applicationWillTerminate (likely SIGTERM-style kill), so
        // the in-app capture-on-quit path never runs. Post a Darwin
        // notification that triggers an explicit
        // captureLastEntryToStores + AppDefaults.synchronize on
        // the app side, then wait for the completion sentinel
        // before terminating. This mirrors the persistence that
        // would happen under a real Cmd+Q quit.
        try postCaptureNowAndWait()

        app.terminate()
        // No settle needed: the captureNowCompleted sentinel
        // already confirmed AppDefaults.synchronize() flushed
        // before we terminated. Re-launch reads a quiescent
        // prefs file.
        app.launch()
        Self.promoteToKey(app)

        let totalAfter = waitForShootLoaded()
        XCTAssertEqual(totalAfter, total,
                       "fixture pair count should be unchanged across relaunch")
        XCTAssertEqual(currentStem(), restoreStem,
                       "relaunch should restore the last-viewed entry, not snap back to index 0")
    }

    /// Indexer cache survives a process restart and the warm
    /// reopen serves entries from the cache (not from a full
    /// re-index). Reads the cache hits / misses counters exposed
    /// in the indexer popover via accessibility identifiers.
    func test_relaunch_servesIndexerCacheHits() throws {
        // First open: indexing runs cold → all misses, zero hits.
        waitForShootLoaded()
        waitForIndexingDone(timeout: 60)
        let (firstHits, firstMisses) = try readCacheCounters()
        XCTAssertEqual(firstHits, 0,
                       "first open has no cache to read from")
        XCTAssertGreaterThan(firstMisses, 0,
                             "first open should miss for every fixture entry")

        // Terminate (no captureNow needed — we're testing the
        // cache, not last-entry restore). The cache file is
        // flushed by finishIndexing, which already ran above.
        app.terminate()
        app.launch()
        Self.promoteToKey(app)

        // Second open: same fixture path, same env. The cache
        // file written by the first launch is still on disk;
        // indexing should serve every entry from cache.
        waitForShootLoaded()
        waitForIndexingDone(timeout: 60)
        let (secondHits, secondMisses) = try readCacheCounters()
        XCTAssertGreaterThan(secondHits, 0,
                             "warm reopen must serve cache hits")
        XCTAssertEqual(secondHits, firstMisses,
                       "every miss the first launch saw should hit on the second")
        XCTAssertLessThan(secondMisses, firstMisses,
                          "second launch should miss less than the first (cold)")
    }

    /// Open the indexer popover, parse the hits + misses values
    /// from the accessibility-identified Text elements, dismiss
    /// the popover. Both counters are aggregated across all
    /// pipelines in `ViewerState.indexerCacheHitsThisOpen`.
    private func readCacheCounters() throws -> (hits: Int, misses: Int) {
        let chip = app.buttons["indexer.statusChip.done"]
        XCTAssertTrue(chip.waitForExistence(timeout: 30),
                      "indexer didn't reach .done in time")
        chip.click()
        defer { chip.click() }    // close the popover
        let hitsText = app.staticTexts["indexer.cache.hits"]
        let missText = app.staticTexts["indexer.cache.misses"]
        XCTAssertTrue(hitsText.waitForExistence(timeout: 3))
        // staticText surfaces its displayed string via either
        // .label OR .value depending on the SwiftUI primitive +
        // OS version; check both.
        let hitsRaw = (hitsText.value as? String) ?? hitsText.label
        let missRaw = (missText.value as? String) ?? missText.label
        let hits  = Int(parseLeadingInt(from: hitsRaw) ?? "") ?? -1
        let miss  = Int(parseLeadingInt(from: missRaw) ?? "") ?? -1
        return (hits, miss)
    }

    /// Read just the leading integer from an accessibility
    /// label like "1247 hits" or "0 misses".
    private func parseLeadingInt(from raw: String) -> String? {
        let prefix = raw.prefix(while: { $0.isNumber })
        return prefix.isEmpty ? nil : String(prefix)
    }

    /// Block until `indexer.statusChip.done` exists.
    private func waitForIndexingDone(timeout: TimeInterval) {
        let chip = app.buttons["indexer.statusChip.done"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout),
                      "indexer didn't reach .done within \(timeout)s")
    }

    /// Post the `captureNow` Darwin notification and wait for the
    /// app's completion sentinel. After completion, the in-app
    /// `captureLastEntryToStores` + `AppDefaults.synchronize` have
    /// both landed, so the relaunch can read a populated
    /// FavoriteShoots/RecentShoots lastEntry mapping.
    private func postCaptureNowAndWait() throws {
        let completed = expectation(description: "uitest.captureNowCompleted")
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let completedName = "dev.frostman.PhotoX.uitest.captureNowCompleted" as CFString
        let box = Unmanaged.passRetained(SentinelBox(expectation: completed))
        defer {
            CFNotificationCenterRemoveObserver(center,
                                                box.toOpaque(),
                                                CFNotificationName(completedName),
                                                nil)
            box.release()
        }
        CFNotificationCenterAddObserver(
            center,
            box.toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<SentinelBox>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .expectation.fulfill()
            },
            completedName,
            nil,
            .deliverImmediately
        )
        let captureName = "dev.frostman.PhotoX.uitest.captureNow" as CFString
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(captureName),
            nil,
            nil,
            true
        )
        wait(for: [completed], timeout: 5)
    }

    /// Mirrors the reference box used by PhotoXSessionUITestCase
    /// (CFNotificationCenter observer registration is pointer-based;
    /// closure capture isn't enough).
    private class SentinelBox {
        let expectation: XCTestExpectation
        init(expectation: XCTestExpectation) {
            self.expectation = expectation
        }
    }
}
