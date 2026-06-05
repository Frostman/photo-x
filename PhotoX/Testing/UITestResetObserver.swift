import AppKit
import Foundation

/// E2E-test-only Darwin notification listener that rewinds
/// `ViewerState` to a fresh-launch baseline so the shared-session
/// `PhotoXSessionUITestCase` can run consecutive tests against the
/// same `XCUIApplication` instance.
///
/// Installed only when `LaunchFlags.uiTestMode` is true — for
/// production builds the type isn't referenced at all and the
/// notification name is opaque. A malicious local process posting
/// the notification at a production install would hit no observer
/// and do nothing.
///
/// Protocol:
///   1. Test posts `dev.frostman.PhotoX.uitest.reset` via
///      `CFNotificationCenterPostNotification` on the Darwin
///      notify center.
///   2. Observer runs `viewerState.resetForUITest()` then re-runs
///      the launch-time bootstrap path (`PHOTOX_SAMPLE_DIR` →
///      `loadShoot`).
///   3. Observer posts `dev.frostman.PhotoX.uitest.resetCompleted`
///      back so the test process can wait deterministically
///      instead of polling the UI.
///
/// Darwin notifications are cross-process by design — the sender
/// (the test runner) and the receiver (PhotoX) are separate
/// processes, so NotificationCenter wouldn't carry across.
@MainActor
enum UITestResetObserver {
    static let resetNotification = "dev.frostman.PhotoX.uitest.reset"
    static let resetCompletedNotification = "dev.frostman.PhotoX.uitest.resetCompleted"
    /// On receipt, capture the user's current position to
    /// FavoriteShoots/RecentShoots and synchronize UserDefaults.
    /// Workaround for `XCUIApplication.terminate()` not invoking
    /// `applicationWillTerminate` — RelaunchTests posts this
    /// before terminating so the relaunch sees a populated
    /// lastEntry to restore from.
    static let captureNowNotification = "dev.frostman.PhotoX.uitest.captureNow"
    static let captureNowCompletedNotification = "dev.frostman.PhotoX.uitest.captureNowCompleted"

    /// Test hook for the "open in new window" path (the one
    /// `FileMenuButtons.openWithPanel(inNewWindow:)` and
    /// `openRecentInNewWindow(path:)` use). The payload path is
    /// read from `<PHOTOX_UITEST_PAYLOAD_DIR>/openInNewWindow.path`,
    /// where `PHOTOX_UITEST_PAYLOAD_DIR` is set by the test at
    /// launch to its own `NSTemporaryDirectory()`. The XCUITest
    /// runner is sandboxed (can't write `/private/tmp`) but the
    /// (unsandboxed) app can read into the runner's container.
    static let openInNewWindowNotification = "dev.frostman.PhotoX.uitest.openInNewWindow"
    static let openInNewWindowCompletedNotification = "dev.frostman.PhotoX.uitest.openInNewWindowCompleted"
    static let openInNewWindowPayloadBasename = "openInNewWindow.path"

    /// Resolve the payload directory the test side set at launch,
    /// or nil if the env var isn't present (production launches).
    private static var payloadDir: URL? {
        guard let raw = ProcessInfo.processInfo.environment["PHOTOX_UITEST_PAYLOAD_DIR"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw)
    }

    /// Test hook for the unsaved-XMP guard surfaces (⌘W
    /// `windowShouldClose` and ⌘Q `applicationShouldTerminate`).
    /// Appends a sentinel `FailedWrite` to the frontmost
    /// window's `failedXMPWrites` so the close / quit prompt
    /// fires deterministically without needing to race a real
    /// write coordinator batch.
    static let injectFailedXMPNotification = "dev.frostman.PhotoX.uitest.injectFailedXMPWrite"
    static let injectFailedXMPCompletedNotification = "dev.frostman.PhotoX.uitest.injectFailedXMPWriteCompleted"

    /// Test hook for "make THIS shoot's window key". Reads the
    /// shoot path from `<PHOTOX_UITEST_PAYLOAD_DIR>/makeWindowKey.path`
    /// and calls `makeKeyAndOrderFront` on the matching window.
    /// Used by `MultiWindowTests.test_keyMonitor_drivesOnlyKeyWindow`
    /// to deterministically pick which window the next arrow-key
    /// event lands on — XCUITest's `XCUIElement.click()` on a
    /// non-key window doesn't reliably promote it to key in our
    /// SwiftUI WindowGroup setup.
    static let makeWindowKeyNotification = "dev.frostman.PhotoX.uitest.makeWindowKey"
    static let makeWindowKeyCompletedNotification = "dev.frostman.PhotoX.uitest.makeWindowKeyCompleted"
    static let makeWindowKeyPayloadBasename = "makeWindowKey.path"

    /// Test hook for `ExportTests` to add an export destination
    /// without driving the NSOpenPanel that the normal `Add
    /// destination` button uses (XCUITest can't reach the open
    /// panel reliably). Payload at
    /// `<PHOTOX_UITEST_PAYLOAD_DIR>/addExportDestination.json` —
    /// `{"path": "/tmp/...", "allowNonEmpty": false}` (the latter
    /// is optional). Calls `ExportSettings.shared.add(path:)` then
    /// applies the optional `allowNonEmpty` mutation via `update`.
    static let addExportDestinationNotification = "dev.frostman.PhotoX.uitest.addExportDestination"
    static let addExportDestinationCompletedNotification = "dev.frostman.PhotoX.uitest.addExportDestinationCompleted"
    static let addExportDestinationPayloadBasename = "addExportDestination.json"

    /// Test hook for `ExportTests/test_exportSingleDestination_partialBatch`
    /// — runs `ExportRunner.startOne` for the destination at the
    /// supplied 0-based index in `ExportSettings.shared.destinations`.
    /// Payload at
    /// `<PHOTOX_UITEST_PAYLOAD_DIR>/runExportSingleDestination.index`
    /// is the index as a plain ASCII integer.
    static let runExportSingleDestinationNotification = "dev.frostman.PhotoX.uitest.runExportSingleDestination"
    static let runExportSingleDestinationCompletedNotification = "dev.frostman.PhotoX.uitest.runExportSingleDestinationCompleted"
    static let runExportSingleDestinationPayloadBasename = "runExportSingleDestination.index"

    /// One-way sentinel fired by `ExportRunner.logBatchCompletion`
    /// when a batch (one-or-N destinations) finishes for any reason
    /// — `done`, `cancelled`, `failed`. Outcome string is written
    /// to `<PHOTOX_UITEST_PAYLOAD_DIR>/exportCompleted.outcome` so
    /// the test side can read it after waiting for the sentinel.
    /// No request notification — tests just listen.
    static let exportCompletedNotification = "dev.frostman.PhotoX.uitest.exportCompleted"
    static let exportCompletedPayloadBasename = "exportCompleted.outcome"

    /// Test hook for setting the export project name. Bypasses the
    /// `export.projectName` TextField — XCUITest's `typeText` on a
    /// SwiftUI TextField with `@FocusState`-managed focus is brittle
    /// (observed "Neither element nor any descendant has keyboard
    /// focus" even after Tab + click); this hook calls
    /// `ExportSettings.shared.setProjectName(_:)` directly. Payload
    /// is the bare name on the first line of
    /// `<PHOTOX_UITEST_PAYLOAD_DIR>/setExportProjectName.name`.
    static let setExportProjectNameNotification = "dev.frostman.PhotoX.uitest.setExportProjectName"
    static let setExportProjectNameCompletedNotification = "dev.frostman.PhotoX.uitest.setExportProjectNameCompleted"
    static let setExportProjectNamePayloadBasename = "setExportProjectName.name"

    /// Read-only debug snapshot of `state.overlays`. The three
    /// toggles (`A` AF-points, `C` clipping, `F` focus-peaking) are
    /// rendered into the Metal canvas, not the AX tree, so XCUITest
    /// can't observe them visually. On receipt the observer writes
    /// `{"afPoints": true, "clipping": false, "focusPeaking": false}`
    /// JSON to `<PHOTOX_UITEST_PAYLOAD_DIR>/readOverlays.json` and
    /// fires the completion sentinel.
    static let readOverlaysNotification = "dev.frostman.PhotoX.uitest.readOverlays"
    static let readOverlaysCompletedNotification = "dev.frostman.PhotoX.uitest.readOverlaysCompleted"
    static let readOverlaysPayloadBasename = "readOverlays.json"

    // MARK: - Export v2 preset/config hooks
    //
    // Mutations target the primary `viewerState.exportConfig` and
    // `ExportPresetsLibrary.shared` (the per-window snapshot read-out
    // is the only hook that resolves a different ViewerState by
    // shoot path; see `readExportConfigSnapshotForWindow`).
    //
    // Naming convention mirrors the existing export hooks: a request
    // notification, a `<Request>Completed` sentinel, and (where
    // payload is needed) a basename for the file under
    // `PHOTOX_UITEST_PAYLOAD_DIR`.

    /// Apply a preset to the current shoot. Payload: the preset name.
    static let applyExportPresetNotification = "dev.frostman.PhotoX.uitest.applyExportPreset"
    static let applyExportPresetCompletedNotification = "dev.frostman.PhotoX.uitest.applyExportPresetCompleted"
    static let applyExportPresetPayloadBasename = "applyExportPreset.name"

    /// Drop preset linkage (destinations remain).
    static let clearExportPresetNotification = "dev.frostman.PhotoX.uitest.clearExportPreset"
    static let clearExportPresetCompletedNotification = "dev.frostman.PhotoX.uitest.clearExportPresetCompleted"

    /// Save the working config as a new preset. Payload: name.
    static let saveExportPresetAsNotification = "dev.frostman.PhotoX.uitest.saveExportPresetAs"
    static let saveExportPresetAsCompletedNotification = "dev.frostman.PhotoX.uitest.saveExportPresetAsCompleted"
    static let saveExportPresetAsPayloadBasename = "saveExportPresetAs.name"

    /// Push working state back to the source preset (no-op if none).
    static let saveBackToExportPresetNotification = "dev.frostman.PhotoX.uitest.saveBackToExportPreset"
    static let saveBackToExportPresetCompletedNotification = "dev.frostman.PhotoX.uitest.saveBackToExportPresetCompleted"

    /// Save working state by overwriting a different preset. Payload: target name.
    static let saveOverwritingExportPresetNotification = "dev.frostman.PhotoX.uitest.saveOverwritingExportPreset"
    static let saveOverwritingExportPresetCompletedNotification = "dev.frostman.PhotoX.uitest.saveOverwritingExportPresetCompleted"
    static let saveOverwritingExportPresetPayloadBasename = "saveOverwritingExportPreset.name"

    /// Reload current shoot's config from its source preset.
    static let reloadFromExportPresetNotification = "dev.frostman.PhotoX.uitest.reloadFromExportPreset"
    static let reloadFromExportPresetCompletedNotification = "dev.frostman.PhotoX.uitest.reloadFromExportPresetCompleted"

    /// Remove a preset from the global library. Payload: name.
    static let removeExportPresetNotification = "dev.frostman.PhotoX.uitest.removeExportPreset"
    static let removeExportPresetCompletedNotification = "dev.frostman.PhotoX.uitest.removeExportPresetCompleted"
    static let removeExportPresetPayloadBasename = "removeExportPreset.name"

    /// Set the library's default-RoWM value (seeded into new presets). Payload: "true"|"false".
    static let setExportDefaultRoWMNotification = "dev.frostman.PhotoX.uitest.setExportDefaultRoWM"
    static let setExportDefaultRoWMCompletedNotification = "dev.frostman.PhotoX.uitest.setExportDefaultRoWMCompleted"
    static let setExportDefaultRoWMPayloadBasename = "setExportDefaultRoWM.bool"

    /// Set the working config's per-shoot RoWM toggle. Payload: "true"|"false".
    static let setExportRoWMNotification = "dev.frostman.PhotoX.uitest.setExportRoWM"
    static let setExportRoWMCompletedNotification = "dev.frostman.PhotoX.uitest.setExportRoWMCompleted"
    static let setExportRoWMPayloadBasename = "setExportRoWM.bool"

    /// Clear the project-name user override and re-derive from EXIF.
    static let resetExportProjectNameNotification = "dev.frostman.PhotoX.uitest.resetExportProjectName"
    static let resetExportProjectNameCompletedNotification = "dev.frostman.PhotoX.uitest.resetExportProjectNameCompleted"

    /// Remove a destination by 0-based index from the current shoot.
    static let removeExportDestinationNotification = "dev.frostman.PhotoX.uitest.removeExportDestination"
    static let removeExportDestinationCompletedNotification = "dev.frostman.PhotoX.uitest.removeExportDestinationCompleted"
    static let removeExportDestinationPayloadBasename = "removeExportDestination.index"

    /// Mutate one field on a destination. Payload JSON:
    /// `{"index": 0, "field": "includeXMP", "value": false}`.
    /// Supported fields: includeARW, includeHIF, includeXMP,
    /// showRejected, showUnrated, allowNonEmpty, removeOrphans
    /// (Bool values); overwrite (one of the policy raw values).
    static let updateExportDestinationNotification = "dev.frostman.PhotoX.uitest.updateExportDestination"
    static let updateExportDestinationCompletedNotification = "dev.frostman.PhotoX.uitest.updateExportDestinationCompleted"
    static let updateExportDestinationPayloadBasename = "updateExportDestination.json"

    /// Drop every preset in the global library (test isolation).
    static let clearExportPresetsLibraryNotification = "dev.frostman.PhotoX.uitest.clearExportPresetsLibrary"
    static let clearExportPresetsLibraryCompletedNotification = "dev.frostman.PhotoX.uitest.clearExportPresetsLibraryCompleted"

    /// Read-only JSON dump of the current shoot's `ShootExportConfig`.
    /// Writes to `<PHOTOX_UITEST_PAYLOAD_DIR>/exportConfigSnapshot.json`.
    static let readExportConfigSnapshotNotification = "dev.frostman.PhotoX.uitest.readExportConfigSnapshot"
    static let readExportConfigSnapshotCompletedNotification = "dev.frostman.PhotoX.uitest.readExportConfigSnapshotCompleted"
    static let readExportConfigSnapshotPayloadBasename = "exportConfigSnapshot.json"

    /// Read-only JSON dump of the `ShootExportConfig` for the
    /// window holding a given shoot path (resolves via
    /// `WindowRegistry.window(forShootPath:)`). Request payload:
    /// the shoot path (text); response written to the same JSON
    /// file as `readExportConfigSnapshot`.
    static let readExportConfigSnapshotForWindowNotification = "dev.frostman.PhotoX.uitest.readExportConfigSnapshotForWindow"
    static let readExportConfigSnapshotForWindowCompletedNotification = "dev.frostman.PhotoX.uitest.readExportConfigSnapshotForWindowCompleted"
    static let readExportConfigSnapshotForWindowRequestBasename = "readExportConfigSnapshotForWindow.path"

    /// Read-only JSON dump of the `ExportPresetsLibrary` state
    /// (default-RoWM + every preset).
    static let readExportPresetsLibraryNotification = "dev.frostman.PhotoX.uitest.readExportPresetsLibrary"
    static let readExportPresetsLibraryCompletedNotification = "dev.frostman.PhotoX.uitest.readExportPresetsLibraryCompleted"
    static let readExportPresetsLibraryPayloadBasename = "exportPresetsLibrary.json"

    /// Simulate an "external" edit to a preset: bumps the preset's
    /// `updatedAt` directly via `library.update(_:)` without
    /// touching the current shoot's `sourcePresetSnapshotAt`. The
    /// only way a shoot can normally observe a stale snapshot is
    /// if some OTHER process / window updated the preset — this
    /// hook simulates that single-window. Payload: the preset name.
    static let bumpExportPresetNotification = "dev.frostman.PhotoX.uitest.bumpExportPreset"
    static let bumpExportPresetCompletedNotification = "dev.frostman.PhotoX.uitest.bumpExportPresetCompleted"
    static let bumpExportPresetPayloadBasename = "bumpExportPreset.name"

    /// Holds the in-flight reset task so back-to-back postings
    /// don't pile up overlapping reloads. The test side waits for
    /// the completion sentinel before posting the next reset, so
    /// in practice this is just defensive.
    private static var currentResetTask: Task<Void, Never>?
    private static weak var viewerState: ViewerState?

    /// Install once at launch from `PhotoXApp.applicationDidFinishLaunching`.
    /// No-op if called more than once.
    static func install(viewerState: ViewerState) {
        guard self.viewerState == nil else { return }
        self.viewerState = viewerState

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = resetNotification as CFString
        // Bridge: CFNotificationCenter callbacks are C functions.
        // Route into a static Swift entry point that MainActor-hops
        // and calls into the captured ViewerState.
        CFNotificationCenterAddObserver(
            center,
            // Use a fixed sentinel pointer for the observer — there's
            // exactly one observer per process for this notification.
            UnsafeRawPointer(bitPattern: 0xDEADBEEF),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleReset()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
        let captureName = captureNowNotification as CFString
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xDEADCAFE),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleCaptureNow()
                }
            },
            captureName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1001),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleOpenInNewWindow()
                }
            },
            openInNewWindowNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1002),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleInjectFailedXMPWrite()
                }
            },
            injectFailedXMPNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1003),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleMakeWindowKey()
                }
            },
            makeWindowKeyNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1004),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleAddExportDestination()
                }
            },
            addExportDestinationNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1005),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleRunExportSingleDestination()
                }
            },
            runExportSingleDestinationNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1006),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleSetExportProjectName()
                }
            },
            setExportProjectNameNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            UnsafeRawPointer(bitPattern: 0xCAFE1007),
            { _, _, _, _, _ in
                Task { @MainActor in
                    UITestResetObserver.handleReadOverlays()
                }
            },
            readOverlaysNotification as CFString,
            nil,
            .deliverImmediately
        )

        // Export v2 preset/config hooks. CFNotificationCenter's
        // callback parameter is a C function pointer, so each
        // registration uses an inline non-capturing closure that
        // hops to the MainActor and calls the typed handler.
        // Sentinel pointers 0xCAFE1008 ..< 0xCAFE1018 reserved.
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1008),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleApplyExportPreset() } },
            applyExportPresetNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1009),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleClearExportPreset() } },
            clearExportPresetNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE100A),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleSaveExportPresetAs() } },
            saveExportPresetAsNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE100B),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleSaveBackToExportPreset() } },
            saveBackToExportPresetNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE100C),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleSaveOverwritingExportPreset() } },
            saveOverwritingExportPresetNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE100D),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleReloadFromExportPreset() } },
            reloadFromExportPresetNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE100E),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleRemoveExportPreset() } },
            removeExportPresetNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE100F),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleSetExportDefaultRoWM() } },
            setExportDefaultRoWMNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1010),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleSetExportRoWM() } },
            setExportRoWMNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1011),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleResetExportProjectName() } },
            resetExportProjectNameNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1012),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleRemoveExportDestination() } },
            removeExportDestinationNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1013),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleUpdateExportDestination() } },
            updateExportDestinationNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1014),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleClearExportPresetsLibrary() } },
            clearExportPresetsLibraryNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1015),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleReadExportConfigSnapshot() } },
            readExportConfigSnapshotNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1016),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleReadExportConfigSnapshotForWindow() } },
            readExportConfigSnapshotForWindowNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1017),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleReadExportPresetsLibrary() } },
            readExportPresetsLibraryNotification as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, UnsafeRawPointer(bitPattern: 0xCAFE1018),
            { _, _, _, _, _ in Task { @MainActor in UITestResetObserver.handleBumpExportPreset() } },
            bumpExportPresetNotification as CFString, nil, .deliverImmediately)

        Log.app.notice("UITestResetObserver: installed (reset + captureNow + openInNewWindow + injectFailedXMPWrite + makeWindowKey + addExportDestination + runExportSingleDestination + setExportProjectName + readOverlays + export v2 preset/config hooks)")
    }

    private static func handleReset() {
        guard let viewerState else { return }
        // Cancel any in-flight reset so we don't run two reloads in
        // parallel. The new task subsumes the old.
        currentResetTask?.cancel()
        currentResetTask = Task { @MainActor in
            // Wipe export config so every session-test starts with
            // no destinations and an empty project name. The
            // per-shoot config persists to disk
            // (Application Support/PhotoX/ExportConfigs/), so we
            // clear both the in-memory state AND the loaded shoot's
            // file after the reset reloads the sample fixture.

            await viewerState.resetForUITest()
            // Re-bootstrap from PHOTOX_SAMPLE_DIR. Deliberately NOT
            // the launch-path's savedStem-first lookup: the
            // previous test's `captureLastEntryToStores` (called
            // by `closeShoot`) populates FavoriteShoots /
            // RecentShoots for this fixture path, so honouring
            // it would land each test on the entry the previous
            // test ended on. Tests that DO want last-entry
            // restoration should use PhotoXFreshLaunchUITestCase
            // and the real launch path.
            if let (shoot, firstFocus) = SamplePathProvider.resolveShoot() {
                await viewerState.loadShoot(shoot, focus: firstFocus)
            }
            // After loadShoot instantiates the per-shoot config
            // for the sample fixture, blank it so every test
            // begins with no destinations / no preset / empty
            // project name. The deriver will then re-derive the
            // project name from EXIF as it flushes.
            if let config = viewerState.exportConfig {
                while !config.destinations.isEmpty {
                    config.removeDestination(id: config.destinations[0].id)
                }
                config.clearPreset()
                config.setProjectNameFromUser("")
            }
            // Wipe the global preset library so each test starts
            // with no presets. Without this, a preset created in
            // one test would survive into the next, contaminating
            // assertions like "library snapshot has exactly N
            // presets".
            let library = ExportPresetsLibrary.shared
            for preset in library.presets {
                library.remove(id: preset.id)
            }
            // Force the workspace back to View. ContentView's
            // shootMissing-onChange auto-switches to View only
            // from .open, and the @Observable update batching
            // across `closeShoot → loadShoot` (two awaits in
            // the same Task) often collapses the
            // `shoot=nil → shoot=…` transition into one
            // SwiftUI tick — so `shootMissing` never observably
            // flips, the `.export → .open` fallback in
            // `ModeWiring` doesn't fire, and a test that left
            // the previous run in .export keeps its successor
            // on the Export pane (no stem pill → next test's
            // `waitForShootLoaded` times out). Posting the
            // workspace-switch notification here makes "View
            // is the default after reset" an invariant.
            NotificationCenter.default.post(
                name: .photoxSwitchWorkspace,
                object: WorkspaceSwitchRequest(mode: .view, target: viewerState))
            postCompletionSentinel()
        }
    }

    /// Test-only "open in new window" entry point. Reads the
    /// payload path from `AppDefaults` (since Darwin notifications
    /// can't carry data), then routes through the same dedup-first
    /// flow that the user-facing menu / Recent ⌥-click uses.
    /// Always posts the completion sentinel so the test side can
    /// proceed deterministically.
    private static func handleOpenInNewWindow() {
        defer { postSentinel(openInNewWindowCompletedNotification) }
        guard let dir = payloadDir else {
            Log.app.warning("UITestResetObserver: openInNewWindow with no PHOTOX_UITEST_PAYLOAD_DIR")
            return
        }
        let payload = dir.appendingPathComponent(openInNewWindowPayloadBasename)
        let raw = (try? String(contentsOf: payload, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: payload)
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            Log.app.warning("UITestResetObserver: openInNewWindow with empty path (file=\(payload.path, privacy: .public))")
            return
        }
        // Dedup first — mirror `FileMenuButtons.openRecentInNewWindow(path:)`.
        if let existing = WindowRegistry.shared.window(forShootPath: path) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let state = WindowRegistry.shared.viewerState(for: existing) {
                NotificationCenter.default.post(
                    name: .photoxSwitchWorkspace,
                    object: WorkspaceSwitchRequest(mode: .view, target: state))
            }
            return
        }
        // Otherwise stash + spawn — the new `WindowRoot.task`
        // consumes the FIFO entry and loads the path.
        WindowRegistry.shared.enqueuePendingShoot(.path(path))
        WindowRegistry.shared.spawnNewWindow?()
    }

    /// Test-only: make the window holding a specific shoot key
    /// + frontmost. Reads the target path from
    /// `<PHOTOX_UITEST_PAYLOAD_DIR>/makeWindowKey.path`. Used by
    /// `test_keyMonitor_drivesOnlyKeyWindow` so we don't have to
    /// rely on XCUITest's click-to-focus heuristics.
    private static func handleMakeWindowKey() {
        guard let dir = payloadDir else {
            Log.app.warning("UITestResetObserver: makeWindowKey with no PHOTOX_UITEST_PAYLOAD_DIR")
            postSentinel(makeWindowKeyCompletedNotification)
            return
        }
        let payload = dir.appendingPathComponent(makeWindowKeyPayloadBasename)
        let raw = (try? String(contentsOf: payload, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: payload)
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            Log.app.warning("UITestResetObserver: makeWindowKey with empty path")
            postSentinel(makeWindowKeyCompletedNotification)
            return
        }
        guard let window = WindowRegistry.shared.window(forShootPath: path) else {
            Log.app.warning("UITestResetObserver: makeWindowKey — no window for path \(path, privacy: .public)")
            postSentinel(makeWindowKeyCompletedNotification)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // makeKeyAndOrderFront returns immediately but AppKit
        // completes the NSApp.keyWindow update on a subsequent
        // main-runloop tick. The test that immediately follows
        // (test_keyMonitor_drivesOnlyKeyWindow) needs the promotion
        // to have landed before the arrow-key event fires —
        // otherwise both windows' local monitors are armed at the
        // moment of the press and both advance. Spin the runloop
        // briefly so the sentinel only fires once NSApp.keyWindow
        // really points at us. 2 s ceiling so a stuck promotion
        // surfaces as a test failure rather than a hang.
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while NSApp.keyWindow !== window && Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
        if NSApp.keyWindow !== window {
            Log.app.warning("UITestResetObserver: makeWindowKey deadline — NSApp.keyWindow never matched target window for \(path, privacy: .public)")
        }
        postSentinel(makeWindowKeyCompletedNotification)
    }

    /// Test-only injection: appends a sentinel `FailedWrite` to
    /// the frontmost window's `failedXMPWrites` so the close /
    /// quit prompt fires deterministically. The intent value is
    /// irrelevant for the prompt — it only checks "is anything
    /// in the map?" via `hasUnsavedXMPWork`.
    private static func handleInjectFailedXMPWrite() {
        defer { postSentinel(injectFailedXMPCompletedNotification) }
        guard let state = WindowRegistry.shared.frontmostViewerState else {
            Log.app.warning("UITestResetObserver: injectFailedXMP with no frontmost state")
            return
        }
        let sentinel = XMPWriteCoordinator.FailedWrite(
            stem: "uitest-sentinel",
            intent: .setRating(5),
            attempts: 1,
            lastError: "uitest-injected failure",
            timestamp: Date())
        state.failedXMPWrites[sentinel.stem] = sentinel
    }

    private static func handleCaptureNow() {
        guard let viewerState else { return }
        viewerState.captureLastEntryToStores()
        // Mirror `AppDelegate.applicationWillTerminate`'s session
        // capture so test-driven `app.terminate()` (which doesn't
        // fire that delegate hook) leaves the same artefacts on
        // disk a real ⌘Q would. Walks every registered window's
        // ViewerState — not just the one that received the
        // captureNow notification.
        let openPaths = WindowRegistry.shared.all
            .compactMap { $0.shoot?.folderURL.path }
        OpenSessionStore.capture(openPaths)
        AppDefaults.shared.synchronize()
        postSentinel(captureNowCompletedNotification)
    }

    /// Test-only: add a destination to `ExportSettings.shared`
    /// without going through the `pickDestinationFolder()` NSOpenPanel
    /// flow. Reads a JSON payload with a `path` and optional
    /// `allowNonEmpty`. After `add(path:)` succeeds, applies the
    /// optional flag via `update(id:_:)` so test 3 in ExportTests
    /// can exercise the overwrite-allowed path.
    private static func handleAddExportDestination() {
        defer { postSentinel(addExportDestinationCompletedNotification) }
        guard let dir = payloadDir else {
            Log.app.warning("UITestResetObserver: addExportDestination with no PHOTOX_UITEST_PAYLOAD_DIR")
            return
        }
        let payload = dir.appendingPathComponent(addExportDestinationPayloadBasename)
        let data = (try? Data(contentsOf: payload)) ?? Data()
        try? FileManager.default.removeItem(at: payload)
        struct AddPayload: Decodable {
            let path: String
            var allowNonEmpty: Bool? = nil
        }
        guard let info = try? JSONDecoder().decode(AddPayload.self, from: data),
              !info.path.isEmpty else {
            Log.app.warning("UITestResetObserver: addExportDestination payload missing or invalid")
            return
        }
        guard let config = viewerState?.exportConfig else {
            Log.app.warning("UITestResetObserver: addExportDestination — no exportConfig (no shoot loaded)")
            return
        }
        let result = config.addDestination(path: info.path)
        guard case .ok = result else {
            Log.app.warning("UITestResetObserver: addExportDestination rejected (\(String(describing: result), privacy: .public))")
            return
        }
        if info.allowNonEmpty == true,
           let dest = config.destinations.last(where: { $0.path == info.path }) {
            config.updateDestination(id: dest.id) { $0.allowNonEmpty = true }
        }
    }

    /// Test-only: run `ExportRunner.startOne` for the destination at
    /// the supplied 0-based index in `ExportSettings.shared.destinations`.
    /// Avoids needing per-row AX identifiers on `ExportDestinationRow`'s
    /// inline Run button — the test just specifies which destination to
    /// fire. Completion is signalled separately by `exportCompleted`.
    private static func handleRunExportSingleDestination() {
        defer { postSentinel(runExportSingleDestinationCompletedNotification) }
        guard let dir = payloadDir else {
            Log.app.warning("UITestResetObserver: runExportSingleDestination with no PHOTOX_UITEST_PAYLOAD_DIR")
            return
        }
        let payload = dir.appendingPathComponent(runExportSingleDestinationPayloadBasename)
        let raw = (try? String(contentsOf: payload, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: payload)
        guard let viewerState, let shoot = viewerState.shoot,
              let config = viewerState.exportConfig else {
            Log.app.warning("UITestResetObserver: runExportSingleDestination — no viewerState / shoot / exportConfig")
            return
        }
        guard let index = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              index >= 0,
              index < config.destinations.count else {
            Log.app.warning("UITestResetObserver: runExportSingleDestination — invalid index '\(raw, privacy: .public)'")
            return
        }
        let dest = config.destinations[index]
        let projectName = config.trimmedProjectName
        viewerState.exportRunner.startOne(
            dest.id,
            entries: shoot.entries,
            entryXMPs: viewerState.entryXMPs,
            projectName: projectName,
            destination: dest)
    }

    /// Test-only: set `ExportSettings.shared.projectName` from a
    /// plain-text payload file. Bypasses the `export.projectName`
    /// TextField — `XCUIElement.typeText` on a SwiftUI TextField
    /// has been observed to fail with "Neither element nor any
    /// descendant has keyboard focus" even after Tab/click, in
    /// our `@FocusState`-driven Export pane. Tests can drive this
    /// directly without exercising the field's focus semantics.
    private static func handleSetExportProjectName() {
        defer { postSentinel(setExportProjectNameCompletedNotification) }
        guard let dir = payloadDir else {
            Log.app.warning("UITestResetObserver: setExportProjectName with no PHOTOX_UITEST_PAYLOAD_DIR")
            return
        }
        let payload = dir.appendingPathComponent(setExportProjectNamePayloadBasename)
        let raw = (try? String(contentsOf: payload, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: payload)
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        viewerState?.exportConfig?.setProjectNameFromUser(name)
    }

    private static func handleReadOverlays() {
        defer { postSentinel(readOverlaysCompletedNotification) }
        guard let viewerState else { return }
        guard let dir = payloadDir else {
            Log.app.warning("UITestResetObserver: readOverlays with no PHOTOX_UITEST_PAYLOAD_DIR")
            return
        }
        let payload = dir.appendingPathComponent(readOverlaysPayloadBasename)
        let snapshot: [String: Bool] = [
            "afPoints":     viewerState.overlays.afPoints,
            "clipping":     viewerState.overlays.clipping,
            "focusPeaking": viewerState.overlays.focusPeaking,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot,
                                                  options: [.sortedKeys]) {
            try? data.write(to: payload)
        }
    }

    /// Production-side helper called by `ExportRunner.logBatchCompletion`
    /// at the canonical batch-completion point. Writes the outcome
    /// string to `<payloadDir>/exportCompleted.outcome` and posts the
    /// `exportCompleted` Darwin notification so the test side can
    /// deterministically wait + then read the outcome. Gated on
    /// `LaunchFlags.uiTestMode` so production launches don't write to
    /// a payload directory that doesn't exist for them.
    static func postExportCompleted(outcome: String) {
        guard LaunchFlags.uiTestMode else { return }
        if let dir = payloadDir {
            let payload = dir.appendingPathComponent(exportCompletedPayloadBasename)
            try? outcome.data(using: .utf8)?.write(to: payload)
        }
        postSentinel(exportCompletedNotification)
    }

    private static func postCompletionSentinel() {
        postSentinel(resetCompletedNotification)
    }

    private static func postSentinel(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Export v2 preset/config handlers

    /// Read a plain-text payload file (used by hooks where the
    /// payload is just one trimmed string). Returns nil if absent
    /// or empty; consumes (removes) the file on success.
    private static func consumeTextPayload(_ basename: String) -> String? {
        guard let dir = payloadDir else { return nil }
        let url = dir.appendingPathComponent(basename)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func currentExportConfig() -> ShootExportConfig? {
        viewerState?.exportConfig
    }

    private static func presetByName(_ name: String) -> ExportPreset? {
        ExportPresetsLibrary.shared.presets.first(where: { $0.name == name })
    }

    private static func handleApplyExportPreset() {
        defer { postSentinel(applyExportPresetCompletedNotification) }
        guard let name = consumeTextPayload(applyExportPresetPayloadBasename),
              let preset = presetByName(name),
              let config = currentExportConfig() else {
            Log.app.warning("UITestResetObserver: applyExportPreset failed (name/preset/config missing)")
            return
        }
        config.applyPreset(preset)
    }

    private static func handleClearExportPreset() {
        defer { postSentinel(clearExportPresetCompletedNotification) }
        currentExportConfig()?.clearPreset()
    }

    private static func handleSaveExportPresetAs() {
        defer { postSentinel(saveExportPresetAsCompletedNotification) }
        guard let name = consumeTextPayload(saveExportPresetAsPayloadBasename),
              let config = currentExportConfig() else {
            Log.app.warning("UITestResetObserver: saveExportPresetAs failed (name/config missing)")
            return
        }
        _ = config.saveAsNewPreset(name: name)
    }

    private static func handleSaveBackToExportPreset() {
        defer { postSentinel(saveBackToExportPresetCompletedNotification) }
        currentExportConfig()?.saveBackToSourcePreset()
    }

    private static func handleSaveOverwritingExportPreset() {
        defer { postSentinel(saveOverwritingExportPresetCompletedNotification) }
        guard let name = consumeTextPayload(saveOverwritingExportPresetPayloadBasename),
              let target = presetByName(name),
              let config = currentExportConfig() else {
            Log.app.warning("UITestResetObserver: saveOverwritingExportPreset failed")
            return
        }
        config.saveOverwriting(presetID: target.id)
    }

    private static func handleReloadFromExportPreset() {
        defer { postSentinel(reloadFromExportPresetCompletedNotification) }
        currentExportConfig()?.reloadFromSourcePreset()
    }

    private static func handleRemoveExportPreset() {
        defer { postSentinel(removeExportPresetCompletedNotification) }
        guard let name = consumeTextPayload(removeExportPresetPayloadBasename),
              let preset = presetByName(name) else {
            Log.app.warning("UITestResetObserver: removeExportPreset failed (name/preset missing)")
            return
        }
        ExportPresetsLibrary.shared.remove(id: preset.id)
    }

    private static func handleSetExportDefaultRoWM() {
        defer { postSentinel(setExportDefaultRoWMCompletedNotification) }
        guard let raw = consumeTextPayload(setExportDefaultRoWMPayloadBasename) else { return }
        ExportPresetsLibrary.shared.defaultReadOnceWriteMany = (raw.lowercased() == "true")
    }

    private static func handleSetExportRoWM() {
        defer { postSentinel(setExportRoWMCompletedNotification) }
        guard let raw = consumeTextPayload(setExportRoWMPayloadBasename),
              let config = currentExportConfig() else { return }
        config.setReadOnceWriteMany(raw.lowercased() == "true")
    }

    private static func handleResetExportProjectName() {
        defer { postSentinel(resetExportProjectNameCompletedNotification) }
        guard let viewerState, let config = viewerState.exportConfig else { return }
        let dates = viewerState.entryExif.values.compactMap(\.dateTime)
        config.resetProjectNameToAuto(dates: dates)
    }

    private static func handleRemoveExportDestination() {
        defer { postSentinel(removeExportDestinationCompletedNotification) }
        guard let raw = consumeTextPayload(removeExportDestinationPayloadBasename),
              let index = Int(raw),
              let config = currentExportConfig(),
              index >= 0, index < config.destinations.count else {
            Log.app.warning("UITestResetObserver: removeExportDestination — invalid index")
            return
        }
        config.removeDestination(id: config.destinations[index].id)
    }

    /// Payload JSON: `{"index": Int, "field": String, "value": Bool|String}`.
    /// Switches on the field name to apply the right mutation.
    private static func handleUpdateExportDestination() {
        defer { postSentinel(updateExportDestinationCompletedNotification) }
        guard let dir = payloadDir else { return }
        let url = dir.appendingPathComponent(updateExportDestinationPayloadBasename)
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        struct Payload: Decodable {
            let index: Int
            let field: String
            // value comes through as either Bool or String depending
            // on the field; decode both, use whichever matches.
            let boolValue: Bool?
            let stringValue: String?
            enum CodingKeys: String, CodingKey { case index, field, value }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.index = try c.decode(Int.self, forKey: .index)
                self.field = try c.decode(String.self, forKey: .field)
                if let b = try? c.decode(Bool.self, forKey: .value) {
                    self.boolValue = b; self.stringValue = nil
                } else if let s = try? c.decode(String.self, forKey: .value) {
                    self.stringValue = s; self.boolValue = nil
                } else {
                    self.boolValue = nil; self.stringValue = nil
                }
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let config = currentExportConfig(),
              payload.index >= 0, payload.index < config.destinations.count else {
            Log.app.warning("UITestResetObserver: updateExportDestination — invalid payload/index")
            return
        }
        let id = config.destinations[payload.index].id
        config.updateDestination(id: id) { dest in
            switch payload.field {
            case "includeARW":    if let v = payload.boolValue { dest.includeARW = v }
            case "includeHIF":    if let v = payload.boolValue { dest.includeHIF = v }
            case "includeXMP":    if let v = payload.boolValue { dest.includeXMP = v }
            case "showRejected":  if let v = payload.boolValue { dest.showRejected = v }
            case "showUnrated":   if let v = payload.boolValue { dest.showUnrated = v }
            case "allowNonEmpty": if let v = payload.boolValue { dest.allowNonEmpty = v }
            case "removeOrphans": if let v = payload.boolValue { dest.removeOrphans = v }
            case "overwrite":
                if let v = payload.stringValue,
                   let policy = ExportPreset.OverwritePolicy(rawValue: v) {
                    dest.overwrite = policy
                }
            default:
                Log.app.warning("UITestResetObserver: updateExportDestination — unknown field \(payload.field, privacy: .public)")
            }
        }
    }

    private static func handleClearExportPresetsLibrary() {
        defer { postSentinel(clearExportPresetsLibraryCompletedNotification) }
        let library = ExportPresetsLibrary.shared
        for preset in library.presets {
            library.remove(id: preset.id)
        }
    }

    /// Codable mirror for the snapshot JSON. Kept inside the
    /// observer so callers don't depend on `ShootExportConfigData`
    /// fields they don't care about (and so renaming model
    /// fields doesn't accidentally break the wire format).
    private struct ExportConfigSnapshot: Encodable {
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

    private struct DestinationSnapshot: Encodable {
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

        init(from dest: ExportPreset.Destination) {
            self.path = dest.path
            self.includeARW = dest.includeARW
            self.includeHIF = dest.includeHIF
            self.includeXMP = dest.includeXMP
            // Sets aren't deterministically ordered; sort for
            // stable diff in assertions.
            self.showStars = dest.showStars.sorted()
            self.showRejected = dest.showRejected
            self.showUnrated = dest.showUnrated
            self.overwrite = dest.overwrite.rawValue
            self.allowNonEmpty = dest.allowNonEmpty
            self.removeOrphans = dest.removeOrphans
        }
    }

    private static func snapshot(of config: ShootExportConfig) -> ExportConfigSnapshot {
        ExportConfigSnapshot(
            projectName: config.projectName,
            projectNameIsUserOverride: config.projectNameIsUserOverride,
            readOnceWriteMany: config.readOnceWriteMany,
            sourcePresetID: config.sourcePresetID?.uuidString,
            sourcePresetNameCached: config.sourcePresetNameCached,
            sourcePresetExists: config.sourcePresetExists,
            isModifiedFromPreset: config.isModifiedFromPreset,
            presetChangedSinceApply: config.presetChangedSinceApply,
            destinations: config.destinations.map(DestinationSnapshot.init(from:))
        )
    }

    private static func writeConfigSnapshot(_ config: ShootExportConfig) {
        guard let dir = payloadDir else { return }
        let url = dir.appendingPathComponent(readExportConfigSnapshotPayloadBasename)
        let snap = snapshot(of: config)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func handleReadExportConfigSnapshot() {
        defer { postSentinel(readExportConfigSnapshotCompletedNotification) }
        guard let config = currentExportConfig() else {
            // Still write an empty file so the test can detect
            // "no config" via the absence of expected fields.
            if let dir = payloadDir {
                let url = dir.appendingPathComponent(readExportConfigSnapshotPayloadBasename)
                try? Data("{}".utf8).write(to: url, options: .atomic)
            }
            return
        }
        writeConfigSnapshot(config)
    }

    private static func handleReadExportConfigSnapshotForWindow() {
        defer { postSentinel(readExportConfigSnapshotForWindowCompletedNotification) }
        guard let path = consumeTextPayload(readExportConfigSnapshotForWindowRequestBasename),
              let window = WindowRegistry.shared.window(forShootPath: path),
              let state = WindowRegistry.shared.viewerState(for: window),
              let config = state.exportConfig else {
            // Same empty-stub fallback as above for absence detection.
            if let dir = payloadDir {
                let url = dir.appendingPathComponent(readExportConfigSnapshotPayloadBasename)
                try? Data("{}".utf8).write(to: url, options: .atomic)
            }
            return
        }
        writeConfigSnapshot(config)
    }

    private struct PresetsLibrarySnapshot: Encodable {
        let defaultReadOnceWriteMany: Bool
        let presets: [PresetSnapshot]
    }
    private struct PresetSnapshot: Encodable {
        let id: String
        let name: String
        let readOnceWriteMany: Bool
        let destinations: [DestinationSnapshot]
    }

    /// Simulate an "external" preset edit: call `library.update`
    /// on the matching preset (which bumps its `updatedAt`)
    /// WITHOUT touching the current shoot's snapshot timestamp.
    /// This is the only way a single-process E2E run can leave a
    /// shoot pointing at a stale snapshot.
    private static func handleBumpExportPreset() {
        defer { postSentinel(bumpExportPresetCompletedNotification) }
        guard let name = consumeTextPayload(bumpExportPresetPayloadBasename),
              let preset = presetByName(name) else {
            Log.app.warning("UITestResetObserver: bumpExportPreset failed (name/preset missing)")
            return
        }
        // Make the bump observable as content change too: tweak a
        // throwaway field. We change the preset's `name` to itself
        // — that's a no-op semantically but goes through
        // `library.update(...)` which bumps `updatedAt`.
        var updated = preset
        updated.name = preset.name
        ExportPresetsLibrary.shared.update(updated)
    }

    private static func handleReadExportPresetsLibrary() {
        defer { postSentinel(readExportPresetsLibraryCompletedNotification) }
        guard let dir = payloadDir else { return }
        let library = ExportPresetsLibrary.shared
        let snap = PresetsLibrarySnapshot(
            defaultReadOnceWriteMany: library.defaultReadOnceWriteMany,
            presets: library.presets.map { preset in
                PresetSnapshot(
                    id: preset.id.uuidString,
                    name: preset.name,
                    readOnceWriteMany: preset.readOnceWriteMany,
                    destinations: preset.destinations.map(DestinationSnapshot.init(from:))
                )
            }
        )
        if let data = try? JSONEncoder().encode(snap) {
            let url = dir.appendingPathComponent(readExportPresetsLibraryPayloadBasename)
            try? data.write(to: url, options: .atomic)
        }
    }
}

