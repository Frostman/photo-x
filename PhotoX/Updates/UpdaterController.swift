import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard controller. Owns the long-lived
/// `SPUStandardUpdaterController` and exposes a SwiftUI-observable
/// `canCheckForUpdates` flag that mirrors Sparkle's KVO property.
@MainActor
@Observable
final class UpdaterController {
    let updater: SPUStandardUpdaterController
    var canCheckForUpdates: Bool

    private var observation: NSKeyValueObservation?

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updater = controller
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        // Bridge Sparkle's KVO into the @Observable surface.
        self.observation = controller.updater.observe(
            \.canCheckForUpdates, options: [.new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }
}
