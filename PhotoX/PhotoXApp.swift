import SwiftUI
import AppKit
import ServiceManagement
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
    @State private var recents = RecentShoots.shared
    /// Build the Sparkle updater unless E2E tests disabled it via
    /// `-photoxDisableSparkle`. Optional so the App keeps a single
    /// nil-safe ref instead of branching every read site.
    @State private var updater: UpdaterController? = LaunchFlags.disableSparkle ? nil : UpdaterController()
    @AppStorage(SettingsKey.appearance, store: AppDefaults.shared) private var appearanceRaw = SettingsKey.Defaults.appearance
    /// Each window publishes its own ViewerState via `.focusedValue`,
    /// so menu commands at this scope target the frontmost window
    /// instead of a stale single instance.
    @FocusedValue(\.viewerState) private var focusedState: ViewerState?

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup(id: WindowID.main) {
            WindowRoot(updater: updater)
                .preferredColorScheme(appearance.colorScheme)
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
                    if let state = focusedState {
                        appDelegate.statsWindowController.show(state: state)
                    }
                } label: {
                    Label("Usage Stats…", systemImage: "chart.bar")
                }
                .disabled(focusedState == nil)
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
                UndoRedoMenuButtons(state: focusedState)
            }

            CommandGroup(replacing: .newItem) {
                FileMenuButtons(recents: recents)
            }
            CommandMenu("View") {
                Button("Fit") {
                    focusedState?.setViewportToFit()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(focusedState == nil)

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
                        guard let target = focusedState else { return }
                        NotificationCenter.default.post(
                            name: .photoxSwitchWorkspace,
                            object: WorkspaceSwitchRequest(mode: tab.mode, target: target))
                    }
                    .keyboardShortcut(tab.shortcut, modifiers: .command)
                    .disabled(focusedState == nil)
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
        // "Settings…" to the app menu. SettingsHost reads the frontmost
        // window's ViewerState from WindowRegistry so Settings → Advanced
        // can show live cache stats for the active shoot.
        Settings {
            SettingsHost()
                .preferredColorScheme(appearance.colorScheme)
        }
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

/// One-shot onboarding alerts that surface PhotoX's two
/// opt-in features (card watcher and usage stats). Each
/// promo shows at most once per bundle (per-bundle "shown"
/// flags in `LocalAppDefaults` so dev and prod prompt
/// independently). At most one promo per launch — stacking
/// two modal alerts on a cold start is rude.
@MainActor
private func presentOnboardingPromosIfNeeded() {
    // E2E test runs skip every first-launch UX so the
    // suite doesn't have to dismiss prompts.
    guard !LaunchFlags.uiTestMode else { return }

    if !LocalAppDefaults.shared.bool(forKey: SettingsKey.onboardingCardWatcherPromoShown) {
        // Skip the prompt (but still mark it shown) if the
        // user already enabled it some other way — Settings
        // toggle, defaults write, etc.
        if !LocalAppDefaults.shared.bool(forKey: SettingsKey.cardWatcherEnabled) {
            runCardWatcherPromo()
        }
        LocalAppDefaults.shared.set(true, forKey: SettingsKey.onboardingCardWatcherPromoShown)
        return
    }

    if !LocalAppDefaults.shared.bool(forKey: SettingsKey.onboardingTelemetryPromoShown) {
        if !AppDefaults.shared.bool(forKey: SettingsKey.telemetryEnabled) {
            runTelemetryPromo()
        }
        LocalAppDefaults.shared.set(true, forKey: SettingsKey.onboardingTelemetryPromoShown)
    }
}

/// Card-watcher opt-in alert. Advertises the
/// notification-on-card-mount UX and the helper's
/// ultra-light footprint. On Enable: flip the per-bundle
/// `cardWatcherEnabled` flag AND call
/// `SMAppService.agent(...).register()` directly so the
/// helper starts immediately without the user having to
/// open Settings.
@MainActor
private func runCardWatcherPromo() {
    let alert = NSAlert()
    alert.messageText = "Watch for camera cards in the background?"
    alert.informativeText = """
    PhotoX can post a notification the moment you insert an SD or CFExpress card with PhotoX shoots on it — click the banner and the shoot opens straight in the current window.

    The helper is ultra-light: it observes the macOS mount event only — no polling, no directory scans — so it idles at 0% CPU and a few MB RAM. You can disable it any time in Settings → Card watcher, or under System Settings → Login Items.
    """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Enable")        // alertFirstButtonReturn
    alert.addButton(withTitle: "Maybe later")   // alertSecondButtonReturn

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    LocalAppDefaults.shared.set(true, forKey: SettingsKey.cardWatcherEnabled)
    do {
        try SMAppService.agent(plistName: CardWatcherSupervisor.plistName).register()
    } catch {
        // Best-effort — the user can still flip the toggle
        // from Settings, which surfaces a more detailed
        // error path. No second alert here.
    }
}

/// Usage-stats opt-in alert. Explicit about being optional
/// and that the stats are always collected locally
/// (visible via Window → Usage Stats…) regardless of this
/// toggle — only the upload is gated. Telemetry is a
/// cross-bundle setting, so the flag goes into
/// `AppDefaults.shared` (not LocalAppDefaults — only the
/// promo-shown flag is per-bundle).
@MainActor
private func runTelemetryPromo() {
    let alert = NSAlert()
    alert.messageText = "Send anonymous usage stats?"
    alert.informativeText = """
    Totally optional, and totally fine to leave off — PhotoX always tracks the same counters locally and you can review them any time via Window → Usage Stats…

    If you opt in, PhotoX uploads just those integer counters (app opens, photos seen, ratings/labels set, shoots opened, exports run) plus a random anonymous ID to a hosted PostHog instance. No filenames, photos, paths, ratings values, or EXIF ever leave your device. You can flip this off again in Settings → Privacy at any time.
    """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Enable")    // alertFirstButtonReturn
    alert.addButton(withTitle: "No thanks") // alertSecondButtonReturn

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    AppDefaults.shared.set(true, forKey: SettingsKey.telemetryEnabled)
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

/// Payload for `.photoxSwitchWorkspace` so workspace-tab switches
/// target a single window rather than broadcasting to every open
/// window. Without the target field, switching the focused window
/// to View also yanked all other windows onto their View tab — a
/// regression introduced when each window got its own ContentView
/// instance observing the notification.
struct WorkspaceSwitchRequest {
    let mode: WorkspaceMode
    /// Receiver of the switch. Held as a reference so observers
    /// can identity-compare (`req.target === state`); the value
    /// never escapes the notification's synchronous delivery.
    let target: ViewerState
}

/// Edit → Undo / Redo menu items, bound to ViewerState.undoManager.
/// Wrapped in its own View so the body re-evaluates when
/// `state.undoStateVersion` bumps — without that, the menu's
/// disabled state and title strings would never refresh, because
/// NSUndoManager itself isn't `@Observable`.
private struct UndoRedoMenuButtons: View {
    /// Resolved from `@FocusedValue(\.viewerState)` at the App
    /// scope; nil when no PhotoX window is the focused frontmost
    /// (e.g. Settings or the About panel is key).
    let state: ViewerState?

    var body: some View {
        // Read the observable counter to register a SwiftUI
        // dependency. Every undo-state change bumps it, which
        // forces this view to re-evaluate `canUndo` / `canRedo`
        // / `undoMenuItemTitle` from the underlying UndoManager.
        let _ = state?.undoStateVersion
        Button(state?.undoManager.undoMenuItemTitle ?? "Undo") {
            state?.undoManager.undo()
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(state?.undoManager.canUndo != true)

        Button(state?.undoManager.redoMenuItemTitle ?? "Redo") {
            state?.undoManager.redo()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(state?.undoManager.canRedo != true)
    }
}

/// File-menu items that need access to SwiftUI's `openWindow`
/// environment action. Lives as a View (not a Commands struct) so
/// it can use `@Environment(\.openWindow)`. The parent
/// `CommandGroup(replacing: .newItem)` invokes it once.
private struct FileMenuButtons: View {
    @Bindable var recents: RecentShoots
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: WindowID.main)
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("Open Folder…") {
            Task { await openWithPanel(inNewWindow: false) }
        }
        .keyboardShortcut("o", modifiers: .command)

        Button("Open in New Window…") {
            Task { await openWithPanel(inNewWindow: true) }
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Menu("Open Recent") {
            ForEach(recents.paths, id: \.self) { path in
                // Hold Option to open the recent in a new window —
                // mirrors Finder's modifier-click convention. Read
                // the modifier state at click-time via NSEvent so
                // SwiftUI's static `Button` action can branch.
                Button(menuLabel(for: path)) {
                    let inNewWindow = NSEvent.modifierFlags.contains(.option)
                    Task {
                        if inNewWindow {
                            openRecentInNewWindow(path: path)
                        } else {
                            await ShootOpener.open(path: path,
                                                    requestedTarget: .replaceFrontmost)
                        }
                    }
                }
                .help("Hold ⌥ to open in a new window")
            }
            if !recents.paths.isEmpty {
                Divider()
                Button("Clear Menu") { recents.clear() }
            }
        }
        .disabled(recents.paths.isEmpty)
    }

    private func openWithPanel(inNewWindow: Bool) async {
        guard let (shoot, focus) = OpenPanelCoordinator.runShootPicker() else { return }
        if inNewWindow {
            // Dedup first — if this shoot is already open in some
            // window, focus that instead of spawning a fresh empty
            // window the user would have to close.
            if let existing = WindowRegistry.shared.window(forShootPath: shoot.folderURL.path) {
                focusDedup(existing)
                return
            }
            WindowRegistry.shared.enqueuePendingShoot(.scanned(shoot: shoot, focus: focus))
            openWindow(id: WindowID.main)
        } else {
            await ShootOpener.open(shoot: shoot, focus: focus, requestedTarget: .replaceFrontmost)
        }
    }

    private func openRecentInNewWindow(path: String) {
        if let existing = WindowRegistry.shared.window(forShootPath: path) {
            focusDedup(existing)
            return
        }
        WindowRegistry.shared.enqueuePendingShoot(.path(path))
        openWindow(id: WindowID.main)
    }

    /// Bring an existing window forward (dedup hit) and post a
    /// View-tab switch targeted at *that* window's ViewerState so
    /// other open windows keep their current tab.
    private func focusDedup(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let target = WindowRegistry.shared.viewerState(for: window) {
            NotificationCenter.default.post(
                name: .photoxSwitchWorkspace,
                object: WorkspaceSwitchRequest(mode: .view, target: target))
        }
    }

    private func menuLabel(for path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Per-window root view that owns the `ViewerState`. SwiftUI
/// instantiates one of these per `WindowGroup` spawn, so each
/// window gets its own state. Registers itself with
/// `WindowRegistry` via a hidden `WindowAccessor` so AppDelegate /
/// ShootOpener / Sparkle can resolve "the frontmost window's
/// state" without a single app-scope reference.
struct WindowRoot: View {
    let updater: UpdaterController?

    @State private var viewerState = ViewerState()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    /// Process-wide latch: bootstrap runs once across all windows.
    @MainActor private static var didBootstrap = false
    @MainActor private static var didInstallTestObserver = false
    @MainActor private static var didRegisterSpawner = false

    /// Window title — `<appName>` for an empty window,
    /// `<appName>: <path>` (path abbreviated with `~`) when a shoot
    /// is loaded. `<appName>` reads `CFBundleDisplayName` so dev
    /// builds advertise as "PhotoXDev" — useful when both the dev
    /// and the installed Release copy are running side by side.
    private var windowTitle: String {
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? "PhotoX"
        guard let url = viewerState.shoot?.folderURL else { return appName }
        let abbrev = (url.path as NSString).abbreviatingWithTildeInPath
        return "\(appName): \(abbrev)"
    }

    var body: some View {
        ContentView(state: viewerState, updater: updater)
            .navigationTitle(windowTitle)
            .focusedValue(\.viewerState, viewerState)
            .background(WindowAccessor { window in
                WindowRegistry.shared.register(window: window, viewerState: viewerState)
                // Window-delegate take-over is handled globally via
                // AppDelegate's `NSWindow.didBecomeMainNotification`
                // observer — `WindowAccessor.updateNSView` fires too
                // early in SwiftUI's setup; SwiftUI overrides our
                // delegate afterward.
                // Maximize every spawned window to the screen's
                // visible frame — culling benefits from the largest
                // possible canvas. Skip under XCUITest so tests see
                // a predictable default frame.
                if !LaunchFlags.uiTestMode,
                   let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: true)
                }
            })
            .task {
                registerSpawnerIfNeeded()
                // Sparkle's shoot-URL provider routes through the
                // registry so it always resolves to the frontmost
                // window's open shoot.
                updater?.shootURLProvider = {
                    WindowRegistry.shared.frontmostViewerState?.shoot?.folderURL
                }
                installUITestResetObserverIfNeeded()

                // Pending-shoot consumption (set by File → Open in
                // New Window, Dock-drop, card-URL router) wins over
                // the default-folder bootstrap.
                let explicitShoot = await consumePendingShootIfAny()
                await firstWindowBootstrapIfNeeded(skipAutoLoad: explicitShoot)
            }
            .onChange(of: scenePhase) { _, phase in
                // On background (Dock-hide / Cmd-Tab) capture the
                // current shoot+stem so a later relaunch can resume on
                // the same entry. Cheap — touches at most two
                // UserDefaults keys. ⌘Q goes through
                // applicationWillTerminate (see AppDelegate) since
                // scenePhase .background is unreliable on quit.
                if phase == .background {
                    viewerState.captureLastEntryToStores()
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .photoxWillTerminate)) { _ in
                viewerState.captureLastEntryToStores()
            }
    }

    /// Caches SwiftUI's `openWindow` env action in the registry so
    /// AppKit-side callbacks (Dock-drop, card-URL router) can spawn
    /// new windows from outside any View context. Registration runs
    /// once per process; subsequent windows leave the cached closure
    /// alone (an `OpenWindowAction` is app-scoped, not tied to the
    /// originating window's lifetime).
    private func registerSpawnerIfNeeded() {
        guard !Self.didRegisterSpawner else { return }
        Self.didRegisterSpawner = true
        WindowRegistry.shared.spawnNewWindow = {
            openWindow(id: WindowID.main)
        }
    }

    private func installUITestResetObserverIfNeeded() {
        guard LaunchFlags.uiTestMode, !Self.didInstallTestObserver else { return }
        Self.didInstallTestObserver = true
        UITestResetObserver.install(viewerState: viewerState)
    }

    /// Loads any pending shoot stashed by a caller that spawned this
    /// window (File → Open in New Window, Dock drop, etc.). Returns
    /// `true` if a shoot was loaded so the bootstrap path can skip
    /// the default-folder auto-load.
    private func consumePendingShootIfAny() async -> Bool {
        guard let pending = WindowRegistry.shared.consumePendingShoot() else { return false }
        switch pending {
        case .path(let path):
            await OpenShootRouter.load(path: path, state: viewerState)
        case .scanned(let shoot, let focus):
            await viewerState.loadShoot(shoot, focus: focus)
        }
        return true
    }

    private func firstWindowBootstrapIfNeeded(skipAutoLoad: Bool) async {
        guard !Self.didBootstrap else { return }
        Self.didBootstrap = true

        // App-open metric (process-wide; piggy-backs on this
        // window's metrics object since all ViewerState metrics
        // persist via the same UserDefaults RMW).
        viewerState.metrics.recordAppOpen()

        await bootstrap(skipAutoLoad: skipAutoLoad)
    }

    private func bootstrap(skipAutoLoad: Bool) async {
        // Caller already loaded a shoot into this window (Open in
        // New Window, Dock drop, etc.) — don't second-guess them
        // with a Sparkle reopen or default-folder auto-load.
        if skipAutoLoad { return }

        // Sparkle-driven restart: if the previous run set a pending
        // reopen path (in the last 10 min), prefer it over the
        // configured default folder. `consume()` always clears the
        // keys, fresh or stale.
        if let reopen = PendingReopenStore.consume() {
            await ShootOpener.open(path: reopen.path, requestedTarget: .replaceFrontmost)
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
            await ShootOpener.open(shoot: shoot, focus: focus, requestedTarget: .replaceFrontmost)
        }
    }
}

/// Backing view for the Settings scene. Looks up the frontmost
/// registered window's ViewerState so Settings → Advanced sees
/// live cache stats from the active shoot. A static placeholder
/// covers the rare case where Settings is opened before any
/// `WindowRoot` has registered (e.g. during early test launch).
private struct SettingsHost: View {
    private static let placeholder = ViewerState()

    var body: some View {
        SettingsView()
            .environment(WindowRegistry.shared.frontmostViewerState ?? Self.placeholder)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    /// Single floating Usage Stats window for the lifetime of the
    /// app. Reusing one instance across clicks (rather than spawning
    /// a new window each time) mirrors `FailedWritesWindowController`.
    let statsWindowController = StatsWindowController()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Folders dropped on the Dock icon (or "Open With PhotoX" from
    /// Finder) — open each in a new window with one-window-per-shoot
    /// dedup. If no windows exist yet (cold launch via Finder), the
    /// pending shoot is claimed by the auto-spawned first window
    /// instead of triggering a second spawn.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folderPaths = urls.compactMap { url -> String? in
            guard url.isFileURL else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return url.path
        }
        guard !folderPaths.isEmpty else { return }
        Task { @MainActor in
            for path in folderPaths {
                if let existing = WindowRegistry.shared.window(forShootPath: path) {
                    existing.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    continue
                }
                WindowRegistry.shared.enqueuePendingShoot(.path(path))
                if WindowRegistry.shared.all.isEmpty {
                    // Cold launch via Finder: the auto-spawned first
                    // window will claim the pending shoot. Don't ask
                    // SwiftUI for a second window.
                    continue
                }
                WindowRegistry.shared.spawnNewWindow?()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // SwiftUI listeners get a synchronous chance to capture state
        // before the process exits; UserDefaults is then synced on
        // the line below so the writes definitely hit disk.
        NotificationCenter.default.post(name: .photoxWillTerminate, object: nil)
        AppDefaults.shared.synchronize()
        // Best-effort indexer-cache flush for every open window. Most
        // of the time each cache was already flushed by finishIndexing;
        // this catches any pending writes (e.g. partial indexing
        // interrupted by quit). RunLoop spin lets the detached encode
        // complete before the process exits — hard-capped at 2 s
        // total so a hung disk can't deadlock quit.
        let caches = WindowRegistry.shared.all.map(\.cache)
        guard !caches.isEmpty else { return }
        let flushDone = DispatchSemaphore(value: 0)
        Task {
            for cache in caches {
                await cache.flush()
            }
            flushDone.signal()
        }
        _ = flushDone.wait(timeout: .now() + .seconds(2))
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
        // Each window owns its own ViewerState (see `WindowRoot`),
        // but AppKit's automatic window tabbing would fuse two windows
        // into one tab group whose shared title-bar chrome contradicts
        // the per-window data model. Keeping tabbing off also hides
        // the "Show Tab Bar" / "Merge All Windows" / "Move Tab to New
        // Window" Window-menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// `WindowRoot`'s `WindowAccessor` handles per-window setup
    /// (registry registration, auto-maximize to the screen's
    /// visible frame). This callback handles app-scope setup and
    /// the global window-delegate observer.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Take ownership of UN delegate so we can suppress notifications
        // when the app is in the foreground and route clicks back into
        // the export sheet.
        UNUserNotificationCenter.current().delegate = self

        // Sync the indexer cache policy from saved settings BEFORE
        // any shoot opens. The Settings UI's `.onChange` handlers
        // catch later toggle flips; this is the cold-start path.
        IndexerCache.reloadPolicyFromDefaults()

        // Start watching kernel memory-pressure events so the two
        // shared LRU caches (MTLTextureCache, PreviewBytesCache)
        // shrink under `.warning` / `.critical` and restore on
        // `.normal`. Idle-window entries are naturally first to
        // evict since they're at the LRU tail.
        MemoryPressureMonitor.shared.start()

        // Bootstrap the background card-watcher helper once per
        // process. The supervisor has its own once-per-session
        // gate, but pinning the call here (rather than in a view
        // `.task`) makes the "one helper, one bootstrap" intent
        // explicit and decouples it from multi-window scene
        // creation. Detached so launchctl I/O doesn't stall app
        // launch; unhealthy outcomes surface as an alert.
        Task.detached(priority: .background) {
            let status = await CardWatcherSupervisor.bootstrapAtLaunch()
            await MainActor.run {
                // Order matters: a broken watcher's "needs
                // attention" alert outranks any promo. Only one
                // promo per launch, so the user never sees two
                // stacked modal alerts on a cold start.
                presentCardWatcherAlertIfNeeded(status: status)
                presentOnboardingPromosIfNeeded()
            }
        }

        // Take over each registered window's delegate so
        // `windowShouldClose` can refuse close while THIS window's
        // export runner is busy. SwiftUI's WindowGroup installs its
        // own `AppKitWindowController` as the delegate during scene
        // setup, AFTER `WindowAccessor.updateNSView` runs — setting
        // the delegate from inside the accessor loses the race. The
        // sweep here (deferred one runloop tick so SwiftUI finishes
        // its own install first) catches the launch window; the
        // `didBecomeKey` observer below covers windows spawned later
        // via ⌘N / ⌘⇧O / Dock-drop.
        DispatchQueue.main.async {
            for window in NSApp.windows where
                WindowRegistry.shared.viewerState(for: window) != nil
                && window.delegate !== self
            {
                window.delegate = self
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            MainActor.assumeIsolated {
                guard let self,
                      let window = notif.object as? NSWindow,
                      WindowRegistry.shared.viewerState(for: window) != nil,
                      window.delegate !== self
                else { return }
                window.delegate = self
            }
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
              let url = URL(string: urlStr),
              url.host == "card",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?
                  .first(where: { $0.name == "path" })?
                  .value
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        // NSAppleEventManager delivers on the main thread but the
        // selector isn't statically annotated as MainActor; hop to
        // the actor for `CardURLRouter` (which touches the
        // MainActor-isolated registry + spawns SwiftUI windows).
        Task { @MainActor in
            CardURLRouter.handle(path: path)
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
    /// Window close = shoot close + window close. Mirrors
    /// `ContentView.closeShootGuarded` (XMP prompt + export prompt
    /// + selective cache cleanup) but driven from the ⌘W / red-
    /// button path. Returns false synchronously and runs the async
    /// confirmation flow in a Task; on full confirmation, calls
    /// `sender.close()` which bypasses `windowShouldClose` so it
    /// won't recurse.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Unknown window (test surfaces, panels) → allow close.
        guard let state = WindowRegistry.shared.viewerState(for: sender) else { return true }
        // Empty window has nothing to clean up — let it close.
        if state.shoot == nil { return true }
        Task { @MainActor in
            // Export prompt (per-window — exports in OTHER windows
            // shouldn't block this one).
            if state.exportRunner.isRunning {
                let alert = makeExportRunningAlert(verb: "close the window")
                if alert.runModal() != .alertSecondButtonReturn { return }
                state.exportRunner.cancelAll()
            }
            // XMP prompt — failed writes + in-flight writes both
            // surface as "unsaved work" for confirmation purposes.
            if await state.hasUnsavedXMPWork() {
                let failedCount = state.failedXMPWrites.count
                let proceed = self.runUnsavedXMPAlert(failedCount: failedCount, verb: "closing")
                if !proceed { return }
                await state.discardAllUnsavedXMPState()
            }
            // Close the shoot first so its cache entries are
            // selectively cleared and last-entry / metrics are
            // captured. Then close the window (NSWindow.close
            // bypasses windowShouldClose → no recursion).
            await state.closeShoot()
            sender.close()
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
        let runningExports = WindowRegistry.shared.all
            .map(\.exportRunner)
            .filter(\.isRunning)
        if !runningExports.isEmpty {
            let alert = makeExportRunningAlert(verb: "quit")
            if alert.runModal() == .alertSecondButtonReturn {
                for runner in runningExports { runner.cancelAll() }
                // fall through to XMP check
            } else {
                return .terminateCancel
            }
        }

        let states = WindowRegistry.shared.all
        guard !states.isEmpty else { return .terminateNow }
        // Always go through the .terminateLater path now: we need an
        // await for the metrics flush regardless of the XMP-failure
        // decision, so consolidating the branches keeps the
        // termination contract simple. Per-window state is
        // consolidated into single counts so the user sees one
        // alert ("3 unsaved writes" across two open shoots) rather
        // than one alert per window.
        Task { @MainActor in
            // Drain any in-memory counter deltas to disk before
            // quit so the next launch's stats window reflects this
            // session's activity. Best-effort, expected to land in
            // tens of ms; failures here never block termination.
            for state in states {
                await state.metrics.flushPending()
            }

            let totalFailed = states.reduce(0) { $0 + $1.failedXMPWrites.count }
            if totalFailed > 0 {
                let proceed = self.runUnsavedXMPAlert(failedCount: totalFailed, verb: "quitting")
                sender.reply(toApplicationShouldTerminate: proceed)
                return
            }
            var anyInFlight = false
            for state in states where !anyInFlight {
                if await state.xmpWriter.hasInFlightWrites {
                    anyInFlight = true
                }
            }
            guard anyInFlight else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let proceed = self.runUnsavedXMPAlert(failedCount: 0, verb: "quitting")
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    /// Modal alert for the unsaved-XMP-writes case. Returns true if
    /// the user chose to quit anyway, false if they want to stay.
    /// Shared unsaved-XMP-writes alert. `verb` drives the sentence
    /// ("quitting" / "closing this window") and the destructive
    /// button label ("Quit anyway" / "Close anyway"). Returns true
    /// if the user chose to proceed (discard the unsaved writes).
    private func runUnsavedXMPAlert(failedCount: Int, verb: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Unsaved rating changes"
        let gerund = verb.prefix(1).uppercased() + verb.dropFirst()
        alert.informativeText = failedCount > 0
            ? "\(failedCount) write\(failedCount == 1 ? "" : "s") to XMP sidecar files have failed. \(gerund) now will lose them. Click \"Stay\" to review them in the Failed XMP Writes window."
            : "Some rating writes are still being written to disk. \(gerund) now might lose them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stay")
        let actionLabel = String(verb.split(separator: " ").first ?? "Proceed").capitalized
        let action = alert.addButton(withTitle: "\(actionLabel) anyway")
        action.hasDestructiveAction = true
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

