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
    }

    // Hardcoded sample auto-load for commit 3. SamplePathProvider replaces this in commit 4.
    private func bootstrap() async {
        let sampleURL = URL(fileURLWithPath: "/Users/frostman/workspace/personal/photo-x/sample/DSC04177.HIF")
        guard FileManager.default.fileExists(atPath: sampleURL.path) else {
            viewerState.errorMessage = "Sample not found at \(sampleURL.path)"
            return
        }

        viewerState.isDecoding = true
        defer { viewerState.isDecoding = false }

        do {
            let decoded = try await HEIFDecoder().decode(url: sampleURL)
            viewerState.currentImage = decoded
            viewerState.lastDecodeMS[.imageIO] = decoded.decodeMS
            viewerState.displayedVariant = .heif
            viewerState.errorMessage = nil
        } catch {
            viewerState.errorMessage = String(describing: error)
        }
    }
}
