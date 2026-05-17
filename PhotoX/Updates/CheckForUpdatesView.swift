import SwiftUI

/// Menu-command button bound to Sparkle. Stays disabled while a check is in
/// progress (matches the standard macOS app-menu UX).
struct CheckForUpdatesView: View {
    let controller: UpdaterController

    var body: some View {
        Button("Check for Updates…") {
            controller.checkForUpdates()
        }
        .disabled(!controller.canCheckForUpdates)
    }
}
