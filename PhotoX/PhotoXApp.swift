import SwiftUI
import AppKit

@main
struct PhotoXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewerState = ViewerState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: viewerState)
                .task { await bootstrap() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    Task { await openWithPanel() }
                }
                .keyboardShortcut("o", modifiers: .command)
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
        }
    }

    private func bootstrap() async {
        if let (shoot, focus) = SamplePathProvider.resolveShoot() {
            await viewerState.loadShoot(shoot, focus: focus)
        } else {
            viewerState.errorMessage = "No ARW + HIF pair found in \(SamplePathProvider.sampleDirectory().path). Drop a folder or pair on the window or use ⌘O."
        }
    }

    private func openWithPanel() async {
        guard let (shoot, focus) = OpenPanelCoordinator.runShootPicker() else { return }
        await viewerState.loadShoot(shoot, focus: focus)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
