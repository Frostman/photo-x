import SwiftUI
import AppKit
import UserNotifications

@main
struct PhotoXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewerState = ViewerState()
    @State private var recents = RecentShoots.shared
    @State private var updater = UpdaterController()
    @AppStorage(SettingsKey.appearance, store: AppDefaults.shared) private var appearanceRaw = SettingsKey.Defaults.appearance

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: viewerState)
                .preferredColorScheme(appearance.colorScheme)
                .task { await bootstrap() }
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
                CheckForUpdatesView(controller: updater)
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
            }
        }

        // Standard macOS Settings scene — binds ⌘, automatically and adds
        // "Settings…" to the app menu.
        Settings {
            SettingsView()
                .preferredColorScheme(appearance.colorScheme)
        }
    }

    private func bootstrap() async {
        // If the user has configured a default folder and it exists with
        // pairs, auto-load it. Otherwise just leave the window in its empty
        // state — no error, no nag.
        if let (shoot, focus) = SamplePathProvider.resolveShoot() {
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
        guard let focus = shoot.pairs.first else {
            viewerState.errorMessage = "No ARW + HIF pairs found in \(url.lastPathComponent)"
            return
        }
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Disable title-bar double-click action (minimize / zoom). NSWindow reads
    /// `AppleActionOnDoubleClick` from our app's NSUserDefaults; setting it
    /// to "None" here overrides the system-wide preference for PhotoX only.
    /// Must run before any window is created → applicationWillFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set("None", forKey: "AppleActionOnDoubleClick")
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

        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain })
            else { return }
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(screen.visibleFrame, display: true)
            }
            // Become the window delegate so we can refuse to close while an
            // export is running. SwiftUI's WindowGroup doesn't set its own
            // delegate, so this slot is free for us.
            window.delegate = self
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

    /// Block quit while an export is in progress.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ExportRunner.shared.isRunning else { return .terminateNow }
        let alert = makeExportRunningAlert(verb: "quit")
        if alert.runModal() == .alertSecondButtonReturn {
            ExportRunner.shared.cancelAll()
            return .terminateNow
        }
        return .terminateCancel
    }

    /// Shared alert for "an export is running, are you sure you want to
    /// <verb>?" Used by both windowShouldClose and applicationShouldTerminate.
    private func makeExportRunningAlert(verb: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Export in progress"
        alert.informativeText = "An export to one or more destinations is still running. \(verb.capitalized(with: nil))ing now will cancel it and leave partially-copied files at the destinations."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stay")                          // default = ⏎
        let cancelBtn = alert.addButton(withTitle: "Cancel exports and \(verb)")
        cancelBtn.hasDestructiveAction = true
        return alert
    }
}
