import SwiftUI

@main
struct PhotoXApp: App {
    @State private var viewerState = ViewerState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: viewerState)
                .task { await bootstrap() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Pair…") {
                    Task { await openWithPanel() }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Fit") {
                    viewerState.setViewportToFit()
                }
                .keyboardShortcut("0", modifiers: .command)
                // ⌘1 actual-pixels lands once the canvas exposes a way for
                // ViewerState to compute oneToOne. Double-click already toggles
                // fit ↔ 1:1 which covers the common case.
            }
        }
    }

    private func bootstrap() async {
        if let pair = SamplePathProvider.firstPair() {
            await viewerState.loadPair(pair)
        } else {
            viewerState.errorMessage = "No ARW + HIF pair found in \(SamplePathProvider.sampleDirectory().path). Drop a pair on the window or use ⌘O."
        }
    }

    private func openWithPanel() async {
        guard let pair = OpenPanelCoordinator.runPairPicker() else { return }
        await viewerState.loadPair(pair)
    }
}
