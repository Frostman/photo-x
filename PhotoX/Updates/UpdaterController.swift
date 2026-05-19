import Foundation
import os
import Sparkle

/// Thin wrapper around Sparkle's standard controller. Owns the long-lived
/// `SPUStandardUpdaterController` and exposes a SwiftUI-observable
/// `canCheckForUpdates` flag that mirrors Sparkle's KVO property.
///
/// **Update policy:**
/// - Background appcast poll every 5 min (SUScheduledCheckInterval).
/// - Auto-download is force-OFF on every Release-build launch — even if
///   the user previously enabled it via Sparkle's preferences. Every
///   update prompt requires explicit confirmation.
/// - If the user dismisses a prompt (closes the panel / "Remind Me
///   Later"), `UpdaterDelegate.declinedVersion` records that version
///   in-memory. Subsequent BACKGROUND checks for the same version are
///   suppressed via `shouldProceedWithUpdate:updateCheck:`. A NEWER
///   version is allowed through (declinedVersion is per-version,
///   not "anything").
/// - App restart clears `declinedVersion` (it's in-memory only).
/// - User-initiated "Check for Updates" also clears `declinedVersion`
///   before triggering — the user is explicitly asking, so always show.
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
        // Force policy on every launch — these persist in user defaults,
        // so we rewrite to keep them in sync with the documented policy
        // regardless of any prior toggling.
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false
        // Immediate check on launch in addition to the scheduled cadence,
        // so the user doesn't wait up to 5 min on first launch.
        controller.updater.checkForUpdatesInBackground()
        #endif
    }

    /// Manual menu trigger. Clears any in-memory "user already declined
    /// this version" suppression — the user is actively asking, so we
    /// always want to surface what's available. Also resets Sparkle's
    /// internal cycle so we don't reuse any "remind me later" cached
    /// state, and the cache-buster query param (see UpdaterDelegate)
    /// ensures the fetch isn't served from a CDN cache either.
    func checkForUpdates() {
        delegate.clearDeclinedVersion()
        updater.updater.resetUpdateCycle()
        updater.checkForUpdates(nil)
    }
}

/// Sparkle delegate. Two responsibilities:
/// 1. Inject a per-request timestamp into the appcast URL so each check
///    bypasses any CDN/HTTP cache (GitHub Raw is fronted by Fastly).
/// 2. Track session-scoped "user declined this version" state so the
///    background poll doesn't repeatedly nag with the same version
///    between user actions.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Last version the user explicitly dismissed during this app run.
    /// Reset by app restart (in-memory) or by an explicit manual
    /// `checkForUpdates`. Lock-protected because Sparkle calls delegate
    /// methods on its own queue.
    private let declined = OSAllocatedUnfairLock<String?>(initialState: nil)

    func clearDeclinedVersion() {
        declined.withLock { $0 = nil }
    }

    nonisolated func feedParameters(for updater: SPUUpdater,
                                    sendingSystemProfile sendingProfile: Bool)
        -> [[String: String]]
    {
        // Unix epoch seconds — unique per request, GitHub Raw ignores
        // unknown query params so the file content returned is the same.
        let t = String(Int(Date().timeIntervalSince1970))
        return [["key": "_t", "value": t]]
    }

    /// Called whenever the user makes a choice on the update panel.
    /// We only care about `.dismiss` (Remind Me Later / closed): record
    /// the version so the next BACKGROUND check skips it.
    nonisolated func updater(_ updater: SPUUpdater,
                              userDidMake choice: SPUUserUpdateChoice,
                              forUpdate updateItem: SUAppcastItem,
                              state: SPUUserUpdateState) {
        guard choice == .dismiss else { return }
        let version = updateItem.versionString
        declined.withLock { $0 = version }
    }

    /// Filter called before Sparkle decides to show / download an
    /// update. Returning `false` (throwing in Swift) silently aborts
    /// the cycle — exactly the suppression we want for the same version
    /// the user already dismissed this session. User-initiated checks
    /// (`SPUUpdateCheckUpdates`) always pass through; we also clear
    /// `declined` in `UpdaterController.checkForUpdates()` so even if
    /// the comparison were applied, it wouldn't match.
    nonisolated func updater(_ updater: SPUUpdater,
                              shouldProceedWithUpdate updateItem: SUAppcastItem,
                              updateCheck: SPUUpdateCheck) throws
    {
        guard updateCheck == .updatesInBackground else { return }
        let declinedVersion = declined.withLock { $0 }
        guard let declinedVersion, declinedVersion == updateItem.versionString else {
            return
        }
        throw NSError(
            domain: "PhotoX.Updater",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Suppressing background prompt for \(declinedVersion) — user dismissed this version earlier this session."
            ]
        )
    }
}
