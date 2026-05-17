import SwiftUI
import AppKit

@main
struct PhotoXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewerState = ViewerState()
    @State private var recents = RecentShoots.shared
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
        URL(fileURLWithPath: path).lastPathComponent
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
