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
        // Debug builds skip Sparkle entirely. The dev binary has the
        // .debug bundle ID and its own version sequence — checking the
        // production appcast would either be a no-op (different bundle
        // ID = irrelevant) or, worse, prompt to "downgrade" the dev
        // build to the latest Release. The Check for Updates menu item
        // stays visible but disabled because canCheckForUpdates remains
        // false (updater never starts).
        #if DEBUG
        let startingUpdater = false
        #else
        let startingUpdater = true
        #endif

        let controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
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

        #if !DEBUG
        // Poll on launch. SUScheduledCheckInterval (15 min) handles the
        // recurring cadence; this guarantees an immediate check even if
        // the last one happened seconds ago in a prior launch.
        controller.updater.checkForUpdatesInBackground()
        #endif
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }
}
