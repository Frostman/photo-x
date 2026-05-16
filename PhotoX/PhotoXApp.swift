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
