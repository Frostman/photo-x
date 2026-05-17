import SwiftUI
import AppKit

@main
struct PhotoXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewerState = ViewerState()
    @State private var recents = RecentShoots.shared
    @State private var updater = UpdaterController()
    @AppStorage(SettingsKey.appearance) private var appearanceRaw = SettingsKey.Defaults.appearance

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Maximize the main window to the screen's visible frame on first launch.
    /// SwiftUI's WindowGroup picks a default size that's smaller than the
    /// screen; for a culling viewer, the larger the canvas the better.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }),
                  let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.visibleFrame, display: true)
        }
    }
}
