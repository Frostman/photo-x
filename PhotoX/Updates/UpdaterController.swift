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

    /// Strong reference — `SPUStandardUpdaterController` holds the delegate
    /// weakly, so it must outlive the updater.
    private let delegate: UpdaterDelegate
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

        let delegate = UpdaterDelegate()
        self.delegate = delegate
        let controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: delegate,
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

    /// Manual menu trigger. Resets Sparkle's internal cycle first so we
    /// don't reuse any "remind me later" cached state — every click does
    /// a fresh appcast fetch + picks the newest version available NOW.
    /// The cache-buster query param (see UpdaterDelegate) ensures the
    /// fetch isn't served from a CDN cache either.
    func checkForUpdates() {
        updater.updater.resetUpdateCycle()
        updater.checkForUpdates(nil)
    }
}

/// Sparkle delegate. Lives only to inject a per-request timestamp into
/// the appcast URL so each check bypasses any CDN/HTTP cache (GitHub
/// Raw is fronted by Fastly and may serve a stale appcast even on a
/// manual user-initiated check). Without this, dismissing v0.140 then
/// clicking Check for Updates a minute later might re-prompt for v0.140
/// instead of finding the freshly-published v0.145.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func feedParameters(for updater: SPUUpdater,
                                    sendingSystemProfile sendingProfile: Bool)
        -> [[String: String]]
    {
        // Unix epoch seconds — unique per request, GitHub Raw ignores
        // unknown query params so the file content returned is the same.
        let t = String(Int(Date().timeIntervalSince1970))
        return [["key": "_t", "value": t]]
    }
}
