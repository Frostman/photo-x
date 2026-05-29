import SwiftUI
import AppKit
import UserNotifications

/// Launch-arg helpers. XCUITest passes argv via
/// `app.launchArguments = ["-photoxDisableSparkle", "YES", ...]` —
/// AppKit splits those into a flat list and exposes them through
/// `ProcessInfo`. We just look for the bare flag NAME; whatever
/// follows it (`"YES"`) is irrelevant. Defined at file scope so
/// AppDelegate can read them too.
enum LaunchFlags {
    static let disableSparkle = ProcessInfo.processInfo.arguments.contains("-photoxDisableSparkle")
    /// Suppresses one-shot first-launch UX (window-maximize side effect,
    /// notification-permission prompt) that would interfere with
    /// XCUITest's expectations of a default frame and a quiet session.
    static let uiTestMode = ProcessInfo.processInfo.arguments.contains("-photoxUITestMode")
}

@main
struct PhotoXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Single instance across the whole app. PhotoX is a single-window
    /// application today — see the comment in
    /// `AppDelegate.applicationWillFinishLaunching` about why AppKit's
    /// automatic window tabbing is disabled. Lifting this requires
    /// moving `viewerState` *inside* the `WindowGroup` body closure
    /// (so SwiftUI gives each new window its own instance) and
    /// retrofitting `ExportRunner` + `AppDelegate` + Sparkle's
    /// shoot-URL provider for multi-instance coordination.
    @State private var viewerState = ViewerState()
    @State private var recents = RecentShoots.shared
    /// Build the Sparkle updater unless E2E tests disabled it via
    /// `-photoxDisableSparkle`. Optional so the App keeps a single
    /// nil-safe ref instead of branching every read site.
    @State private var updater: UpdaterController? = LaunchFlags.disableSparkle ? nil : UpdaterController()
    @AppStorage(SettingsKey.appearance, store: AppDefaults.shared) private var appearanceRaw = SettingsKey.Defaults.appearance
    @Environment(\.scenePhase) private var scenePhase

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: viewerState, updater: updater)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    // Provide the updater with a way to read the
                    // currently-open shoot URL right before Sparkle
                    // quits the app for an install — captured into
                    // PendingReopenStore so bootstrap can resume it.
                    updater?.shootURLProvider = { [weak viewerState] in
                        viewerState?.shoot?.folderURL
                    }
                    // Hand the state to the AppDelegate so the
                    // quit-confirm path can inspect failed /
                    // in-flight XMP writes.
                    appDelegate.viewerState = viewerState
                    await bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    // On background (Dock-hide / Cmd-Tab) capture the
                    // current shoot+stem so a later relaunch can
                    // resume on the same entry. Cheap — touches at
                    // most two UserDefaults keys. ⌘Q goes through
                    // applicationWillTerminate (see below) since
                    // scenePhase .background is unreliable on quit.
                    if phase == .background {
                        viewerState.captureLastEntryToStores()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .photoxWillTerminate)) { _ in
                    viewerState.captureLastEntryToStores()
                }
                // URL routing for `photox(-dev)://card?path=…`
                // (posted by the background card watcher's
                // notification) is handled by
                // `AppDelegate.handleURLAppleEvent`. SwiftUI's
                // `.onOpenURL` was tried first but kept
                // spawning a fresh WindowGroup scene with a
                // mirror `ViewerState`; an `NSAppleEventManager`
                // hijack registered in
                // `applicationWillFinishLaunching` cleanly
                // intercepts the URL before SwiftUI sees it.
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            // Custom About panel: shows the full git-derived version including
            // sha. macOS's default About panel would just show CFBundleShortVersionString
            // ("0.86.0"), losing the commit identifier.
            CommandGroup(replacing: .appInfo) {
                Button {
                    showAboutPanel()
                } label: {
                    Label("About PhotoX", systemImage: "info.circle")
                }
            }
            CommandGroup(after: .appInfo) {
                if let updater {
                    CheckForUpdatesView(controller: updater)
                }
                // Sits in the PhotoX menu directly below "Check for
                // Updates" — it's a long-lived inspector, not a file /
                // window action. No keyboard shortcut so a stray press
                // during fast nav can't surface it accidentally.
                Button {
                    appDelegate.statsWindowController.show(state: viewerState)
                } label: {
                    Label("Usage Stats…", systemImage: "chart.bar")
                }
            }
            // Bind Cmd+Z / Cmd+Shift+Z to ViewerState's UndoManager.
            // We can't use `.environment(\.undoManager, ...)` because
            // SwiftUI's undoManager environment value is read-only
            // (system-managed by the focus chain — TextEditor etc.
            // pick it up). Replacing the standard Edit menu's Undo /
            // Redo entries with our own buttons targets our stack
            // directly. Labels read from `undoMenuItemTitle` /
            // `redoMenuItemTitle` so the menu reads "Undo Rate 5
            // Stars", "Undo Reject", etc.
            CommandGroup(replacing: .undoRedo) {
                UndoRedoMenuButtons(state: viewerState)
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    Task { await openWithPanel() }
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(recents.paths, id: \.self) { path in
                        Button(menuLabel(for: path)) {
                            Task { await openPath(path) }
                        }
                    }
                    if !recents.paths.isEmpty {
                        Divider()
                        Button("Clear Menu") { recents.clear() }
                    }
                }
                .disabled(recents.paths.isEmpty)
            }
            CommandMenu("View") {
                Button("Fit") {
                    viewerState.setViewportToFit()
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                // One menu item per workspace tab, generated
                // from `workspaceTabs`. Posting the single
                // parameterised notification keeps focus
                // intact (we don't want to wrest the project-
                // name TextField's keystrokes while a user is
                // typing) and scales for free as new tabs are
                // added.
                ForEach(workspaceTabs) { tab in
                    Button("Switch to \(tab.title)") {
                        NotificationCenter.default.post(
                            name: .photoxSwitchWorkspace,
                            object: tab.mode)
                    }
                    .keyboardShortcut(tab.shortcut, modifiers: .command)
                }
            }
            // Help → "Keyboard Shortcuts" — pulls up the flat
            // reference card (the old HelpOverlay). Annotated
            // help is a separate surface triggered by `?` /
            // the toolbar button; this menu item exists so
            // the comprehensive shortcut list stays
            // discoverable from the menu bar.
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(
                        name: .photoxShowKeyboardShortcuts,
                        object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // Standard macOS Settings scene — binds ⌘, automatically and adds
        // "Settings…" to the app menu. The viewerState environment lets
        // Settings → Advanced read live cache stats (per-texture bytes,
        // current count, etc.) from the currently-loaded shoot.
        Settings {
            SettingsView()
                .environment(viewerState)
                .preferredColorScheme(appearance.colorScheme)
        }
    }

    private func bootstrap() async {
        // Pick up any new card-watcher binary inside this app
        // bundle and recover if launchd lost track of the
        // helper. See `CardWatcherSupervisor.bootstrapAtLaunch`
        // for the full state machine — running → bounce,
        // registered-but-stopped → start, SM/launchd-desync →
        // re-register + start. Detached so the shoot-load /
        // updater work below isn't gated on launchctl I/O.
        // After the bootstrap finishes we surface unhealthy
        // outcomes via an alert so the user actually notices
        // the watcher is broken (rather than only seeing it
        // in Settings the next time they open the pane).
        Task.detached(priority: .background) {
            let status = await CardWatcherSupervisor.bootstrapAtLaunch()
            await MainActor.run {
                presentCardWatcherAlertIfNeeded(status: status)
            }
        }

        // Sparkle-driven restart: if the previous run set a pending
        // reopen path (in the last 10 min), prefer it over the
        // configured default folder. `consume()` always clears the
        // keys, fresh or stale.
        if let reopen = PendingReopenStore.consume() {
            await openPath(reopen.path)
            return
        }
        // If the user has configured a default folder and it exists with
        // pairs, auto-load it. Otherwise just leave the window in its empty
        // state — no error, no nag.
        if let (shoot, firstFocus) = SamplePathProvider.resolveShoot() {
            // Restore the last-viewed entry if the default folder is
            // also a known favorite/recent. Otherwise focus the first
            // entry (current behavior).
            let path = shoot.folderURL.path
            let savedStem = FavoriteShoots.shared.lastEntry(for: path)
                         ?? RecentShoots.shared.lastEntry(for: path)
            let focus = savedStem
                .flatMap { stem in shoot.entries.first { $0.stem == stem } }
                ?? firstFocus
            await viewerState.loadShoot(shoot, focus: focus)
        }
    }

    private func openWithPanel() async {
        guard let (shoot, focus) = OpenPanelCoordinator.runShootPicker() else { return }
        await viewerState.loadShoot(shoot, focus: focus)
    }

    private func openPath(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            viewerState.errorMessage = "Folder no longer exists: \(path)"
            return
        }
        let shoot = ShootScanner.scan(folder: url)
        guard let firstFocus = shoot.entries.first else {
            viewerState.errorMessage = "No ARW + HIF/JPG pairs (or standalone HIF/JPG files) found in \(url.lastPathComponent)"
            return
        }
        let savedStem = FavoriteShoots.shared.lastEntry(for: path)
                     ?? RecentShoots.shared.lastEntry(for: path)
        let focus = savedStem
            .flatMap { stem in shoot.entries.first { $0.stem == stem } }
            ?? firstFocus
        await viewerState.loadShoot(shoot, focus: focus)
    }

    private func menuLabel(for path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func showAboutPanel() {
        let git = (Bundle.main.object(forInfoDictionaryKey: "GitDescribe") as? String) ?? ""
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if !git.isEmpty {
            // Replaces "Version X.Y.Z" / "X.Y.Z (build)" with the full
            // git-derived identifier so the running build is unambiguous.
            options[.applicationVersion] = git
            options[.version] = ""
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// Surfaces an actionable alert when the card-watcher
/// supervisor finishes its launch-time bootstrap in an
/// unhealthy state — typically a stale BTM/LWCR cache that
/// only a manual System Settings → Login Items toggle can
/// reset. Silent on healthy states (`.running`,
/// `.notRegistered` when the user has opted out, etc.).
@MainActor
private func presentCardWatcherAlertIfNeeded(status: CardWatcherSupervisor.LiveStatus) {
    let body: String
    switch status {
    case .running, .notRegistered, .requiresApproval, .unknown:
        // Healthy / opted-out / awaiting first-run approval —
        // either nothing's wrong or the existing Settings UI
        // already surfaces the next step in-context.
        return
    case .spawnFailed(let code):
        body = """
        macOS refused to start the background card-watcher helper (exit \(code)). This usually happens after the helper is rebuilt: macOS caches a code-signing requirement that no longer matches the new binary, and only a manual toggle resets the cache.

        To fix:
        1. Open System Settings → General → Login Items & Extensions.
        2. Under "Allow in the Background", toggle PhotoX off, then back on.
        3. In PhotoX Settings → Card watcher, click Restart.
        """
    case .registeredNotRunning:
        body = """
        The background card-watcher helper is registered but not running. macOS may be throttling respawn, or its launch-constraint cache is out of date.

        Try toggling PhotoX off and back on under System Settings → Login Items & Extensions → Allow in the Background, then click Restart in PhotoX Settings → Card watcher.
        """
    }

    let alert = NSAlert()
    alert.messageText = "Card watcher needs attention"
    alert.informativeText = body
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open Login Items")  // alertFirstButtonReturn
    alert.addButton(withTitle: "Later")             // alertSecondButtonReturn
    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

/// Broadcast right before the app quits. ViewerState listens (via
/// PhotoXApp's `.onReceive`) and captures the current shoot's last-
/// viewed entry so a relaunch can resume on it. scenePhase
/// `.background` is not reliable on ⌘Q — it can be skipped entirely
/// or fire too late for the UserDefaults write to flush — so we use
/// `applicationWillTerminate` instead.
extension Notification.Name {
    static let photoxWillTerminate = Notification.Name("dev.frostman.PhotoX.willTerminate")
    /// Posted by the Help → "Keyboard Shortcuts" menu item.
    /// ContentView observes it and toggles the flat shortcuts
    /// reference card. Menu items are owned by the App scope
    /// and can't reach @State in ContentView directly, so the
    /// notification is the bridge.
    static let photoxShowKeyboardShortcuts = Notification.Name("dev.frostman.PhotoX.showKeyboardShortcuts")
    /// Posted by each "Switch to <Tab>" View-menu item.
    /// `object` is the target `WorkspaceMode`. ContentView
    /// observes once and dispatches based on the object —
    /// scales with new tabs without adding more notification
    /// names. Going through the App-level menu (instead of an
    /// `.onKeyPress` on ContentView) means the shortcuts still
    /// work when focus is on the export pane's TextField.
    static let photoxSwitchWorkspace = Notification.Name("dev.frostman.PhotoX.switchWorkspace")
}

/// Edit → Undo / Redo menu items, bound to ViewerState.undoManager.
/// Wrapped in its own View so the body re-evaluates when
/// `state.undoStateVersion` bumps — without that, the menu's
/// disabled state and title strings would never refresh, because
/// NSUndoManager itself isn't `@Observable`.
private struct UndoRedoMenuButtons: View {
    let state: ViewerState

    var body: some View {
        // Read the observable counter to register a SwiftUI
        // dependency. Every undo-state change bumps it, which
        // forces this view to re-evaluate `canUndo` / `canRedo`
        // / `undoMenuItemTitle` from the underlying UndoManager.
        let _ = state.undoStateVersion
        Button(state.undoManager.undoMenuItemTitle) {
            state.undoManager.undo()
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!state.undoManager.canUndo)

        Button(state.undoManager.redoMenuItemTitle) {
            state.undoManager.redo()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!state.undoManager.canRedo)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    /// Wired by `PhotoXApp` via `.onAppear` so the
    /// `applicationShouldTerminate` quit-confirm can inspect failed
    /// XMP writes + the coordinator's in-flight state. Weak so the
    /// delegate doesn't artificially extend the state's lifetime.
    weak var viewerState: ViewerState? {
        didSet {
            // Fires once per process on the first wire-up — the
            // WindowGroup .task runs after launch and assigns from
            // nil to non-nil. Subsequent File -> New Window calls
            // re-fire the .task but viewerState is already set; the
            // didRecordAppOpen flag gates double-counting.
            guard !didRecordAppOpen, let viewerState else { return }
            didRecordAppOpen = true
            // recordAppOpen is MainActor-isolated; didSet runs in a
            // nonisolated context (Swift can't statically prove the
            // setter caller is on MainActor). Trampoline via Task to
            // satisfy the compiler. The .task block doing the
            // assignment is already on MainActor, so this is a
            // single hop with no real cross-actor cost.
            Task { @MainActor [viewerState] in
                viewerState.metrics.recordAppOpen()
            }
        }
    }
    private var didRecordAppOpen = false

    /// Single floating Usage Stats window for the lifetime of the
    /// app. Reusing one instance across clicks (rather than spawning
    /// a new window each time) mirrors `FailedWritesWindowController`.
    let statsWindowController = StatsWindowController()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // SwiftUI listeners get a synchronous chance to capture state
        // before the process exits; UserDefaults is then synced on
        // the line below so the writes definitely hit disk.
        NotificationCenter.default.post(name: .photoxWillTerminate, object: nil)
        AppDefaults.shared.synchronize()
        // Best-effort indexer-cache flush. Most of the time the
        // cache was already flushed by finishIndexing; this catches
        // any pending writes (e.g. partial indexing interrupted by
        // quit). RunLoop spin lets the detached encode complete
        // before the process exits — hard-capped at 2 s so a hung
        // disk can't deadlock quit.
        if let state = viewerState {
            let cache = state.cache
            let flushDone = DispatchSemaphore(value: 0)
            Task {
                await cache.flush()
                flushDone.signal()
            }
            _ = flushDone.wait(timeout: .now() + .seconds(2))
        }
    }

    /// Disable title-bar double-click action (minimize / zoom). NSWindow reads
    /// `AppleActionOnDoubleClick` from our app's NSUserDefaults; setting it
    /// to "None" here overrides the system-wide preference for PhotoX only.
    /// Must run before any window is created → applicationWillFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set("None", forKey: "AppleActionOnDoubleClick")

        // Install our `kAEGetURL` Apple Event handler BEFORE
        // SwiftUI has a chance to register its own. SwiftUI's
        // own handler kept spawning a fresh WindowGroup scene
        // for incoming `photox-dev://card?…` events (the new
        // scene's `.task { await bootstrap() }` would re-fire
        // bootstrap, an easy fingerprint in the watcher log).
        // Winning the setEventHandler race here lets us route
        // the URL through the existing `viewerState`.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(self.handleURLAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // PhotoX is single-window today (ViewerState + ExportRunner +
        // this AppDelegate's weak ref all assume one viewer at a time).
        // Opting out of AppKit's automatic window tabbing hides the
        // "Show Tab Bar" / "Merge All Windows" / "Move Tab to New
        // Window" Window-menu items that would otherwise expose a tab
        // bar that has no useful second tab to populate. Re-evaluate
        // when multi-window support lands; see the note on
        // `PhotoXApp.viewerState`.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Maximize the main window to the screen's visible frame on first launch.
    /// SwiftUI's WindowGroup picks a default size that's smaller than the
    /// screen; for a culling viewer, the larger the canvas the better.
    /// Also installs us as the window's delegate so windowShouldClose can
    /// intercept red-button / ⌘W close during an export.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Take ownership of UN delegate so we can suppress notifications
        // when the app is in the foreground and route clicks back into
        // the export sheet.
        UNUserNotificationCenter.current().delegate = self

        // E2E shared-session test support: install a Darwin
        // notification listener that the test runner uses to rewind
        // ViewerState to a fresh-launch baseline between tests
        // (avoids the ~25 s per-test cold-start tax). Gated on the
        // launch flag — production never registers an observer.
        if LaunchFlags.uiTestMode, let state = viewerState {
            UITestResetObserver.install(viewerState: state)
        }

        // Sync the indexer cache policy from saved settings BEFORE
        // any shoot opens. The Settings UI's `.onChange` handlers
        // catch later toggle flips; this is the cold-start path.
        IndexerCache.reloadPolicyFromDefaults()

        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain })
            else { return }
            // Skip the auto-maximize under -photoxUITestMode YES so
            // XCUITest sees a predictable default frame (the maximize
            // races with the test's first query and can return stale
            // coordinates).
            if !LaunchFlags.uiTestMode,
               let screen = window.screen ?? NSScreen.main {
                window.setFrame(screen.visibleFrame, display: true)
            }
            // Become the window delegate so we can refuse to close while an
            // export is running. SwiftUI's WindowGroup doesn't set its own
            // delegate, so this slot is free for us.
            window.delegate = self
        }
    }

    // MARK: URL scheme (Apple Event hijack)

    /// Receives `kAEGetURL` events from LaunchServices when
    /// the helper's notification action calls
    /// `NSWorkspace.shared.open(photox-dev://card?path=…)`.
    /// Registered in `applicationDidFinishLaunching` AFTER
    /// SwiftUI's own URL routing so we override it — see the
    /// comment there for why bypassing SwiftUI is necessary.
    @objc func handleURLAppleEvent(_ event: NSAppleEventDescriptor,
                                   withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlStr = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlStr) else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard url.host == "card",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?
                  .first(where: { $0.name == "path" })?
                  .value,
              let state = viewerState else { return }
        Task { @MainActor in
            await openCardURL(path: path, state: state)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Foreground-delivery hook. If the user is looking at PhotoX when an
    /// export finishes, don't pop a banner — the pill + sheet show the
    /// outcome better than a notification would.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if NSApplication.shared.isActive {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    /// Click handler. Just bring the app to the front — the user can
    /// inspect the toolbar pill / open the Export sheet themselves if they
    /// want details. Popping the sheet automatically was too aggressive
    /// (it interrupted whatever they were already doing in the window).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        completionHandler()
    }

    /// Refuse to close the window while an export is in flight, unless the
    /// user explicitly confirms via the alert. Without this, the red-button
    /// (or ⌘W) close happens BEFORE applicationShouldTerminate runs — so
    /// the window vanishes and the user sees the alert against an empty
    /// app. We intercept here so the window stays put when the user picks
    /// Stay.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard ExportRunner.shared.isRunning else { return true }
        let alert = makeExportRunningAlert(verb: "close the window")
        if alert.runModal() == .alertSecondButtonReturn {
            ExportRunner.shared.cancelAll()
            return true
        }
        return false
    }

    /// Block quit while an export is in progress, OR while XMP
    /// writes have failed / are still in flight. Saving culling
    /// decisions is the project's top promise (see project memory
    /// `project_xmp_write_reliability.md`) — silently letting the
    /// user quit with unsaved ratings would break it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Export check first (existing behaviour). If the user picks
        // "Cancel exports and quit", fall through to the XMP check;
        // we can still bail on the XMP step before actually quitting.
        if ExportRunner.shared.isRunning {
            let alert = makeExportRunningAlert(verb: "quit")
            if alert.runModal() == .alertSecondButtonReturn {
                ExportRunner.shared.cancelAll()
                // fall through to XMP check
            } else {
                return .terminateCancel
            }
        }

        guard let state = viewerState else { return .terminateNow }
        // Always go through the .terminateLater path now: we need an
        // await for the metrics flush regardless of the XMP-failure
        // decision, so consolidating the branches keeps the
        // termination contract simple.
        Task { @MainActor in
            // Drain any in-memory counter deltas to disk before
            // quit so the next launch's stats window reflects this
            // session's activity. Best-effort, expected to land in
            // tens of ms; failures here never block termination.
            await state.metrics.flushPending()

            let failedCount = state.failedXMPWrites.count
            if failedCount > 0 {
                let proceed = self.runUnsavedXMPAlert(failedCount: failedCount)
                sender.reply(toApplicationShouldTerminate: proceed)
                return
            }
            let inFlight = await state.xmpWriter.hasInFlightWrites
            guard inFlight else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let proceed = self.runUnsavedXMPAlert(failedCount: 0)
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    /// Modal alert for the unsaved-XMP-writes case. Returns true if
    /// the user chose to quit anyway, false if they want to stay.
    private func runUnsavedXMPAlert(failedCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Unsaved rating changes"
        alert.informativeText = failedCount > 0
            ? "\(failedCount) write\(failedCount == 1 ? "" : "s") to XMP sidecar files have failed. Quitting now will lose them. Click \"Stay\" to review them in the Failed XMP Writes window."
            : "Some rating writes are still being written to disk. Quitting now might lose them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stay")
        let quitBtn = alert.addButton(withTitle: "Quit anyway")
        quitBtn.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

}

/// Shared alert for "an export is running, are you sure you
/// want to <verb>?" Used by `AppDelegate.windowShouldClose`,
/// `AppDelegate.applicationShouldTerminate`, AND the
/// top-level `openCardURL` URL handler. File-scope so all
/// three call sites stay on the same wording.
@MainActor
fileprivate func makeExportRunningAlert(verb: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Export in progress"
    alert.informativeText = "An export to one or more destinations is still running. \(verb.capitalized(with: nil))ing now will cancel it and leave partially-copied files at the destinations."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Stay")                          // default = ⏎
    let cancelBtn = alert.addButton(withTitle: "Cancel exports and \(verb)")
    cancelBtn.hasDestructiveAction = true
    return alert
}

/// URL-scheme entry point used by `WindowGroup`'s
/// `.onOpenURL` when the background card watcher's
/// notification action fires. Same close-shoot +
/// export-confirmation flow that
/// `ContentView.closeShootGuarded()` uses:
/// - Same path already loaded → just hop to View tab.
/// - Different shoot + export in flight → show the shared
///   "Export in progress" alert and only proceed if the
///   user picks the destructive action.
/// - Otherwise → load and hop to View.
@MainActor
fileprivate func openCardURL(path: String, state: ViewerState) async {
    if state.shoot?.folderURL.path == path {
        NotificationCenter.default.post(
            name: .photoxSwitchWorkspace, object: WorkspaceMode.view)
        return
    }
    if state.shoot != nil, ExportRunner.shared.isRunning {
        let alert = makeExportRunningAlert(verb: "switch to the card")
        if alert.runModal() != .alertSecondButtonReturn {
            return
        }
        ExportRunner.shared.cancelAll()
    }
    await OpenShootRouter.load(path: path, state: state)
    NotificationCenter.default.post(
        name: .photoxSwitchWorkspace, object: WorkspaceMode.view)
}
