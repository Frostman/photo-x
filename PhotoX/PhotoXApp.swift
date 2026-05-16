import SwiftUI

@main
struct PhotoXApp: App {
    @State private var viewerState = ViewerState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: viewerState)
        }
        .windowResizability(.contentMinSize)
    }
}
