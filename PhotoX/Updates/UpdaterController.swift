import AppKit
import Foundation
import os
import Sparkle

/// Sparkle 2 wrapper that surfaces auto-update state through a
/// passive titlebar pill instead of Sparkle's modal sheet.
///
/// Flow:
///
///  1. Sparkle's background poll (every 5 min) finds an update and
///     calls into `PhotoXUserDriver.showUpdateFound`, which forwards
///     to `captureAvailable(...)`. That flips `availableUpdate` to
///     `.available(...)`. The titlebar pill renders.
///  2. The user clicks the pill, which calls
///     `userClickedAvailable()`. We replay Sparkle's stashed reply
///     with `.install`, kicking off Sparkle's stock download +
///     release-notes UI (rendered by the inner SPUStandardUserDriver
///     via forwarded methods).
///  3. Sparkle finishes downloading and calls
///     `showReadyToInstallAndRelaunch`. We forward to
///     `captureReadyToInstall(...)`, flipping the pill to
///     `.readyToInstall(...)`.
///  4. The user clicks the pill again, triggering
///     `confirmRestartAndInstall(currentShootURL:)`. An NSAlert
///     confirms the restart, the shoot URL is stashed via
///     `PendingReopenStore`, and Sparkle's saved reply is invoked
///     with `.install` — the app quits, Sparkle installs, and
///     `PhotoXApp.bootstrap()` consumes the stored URL on relaunch.
///
/// **Why the lower-level SPUUpdater + custom user driver?**
/// SPUStandardUpdaterController doesn't expose a slot to inject a
/// custom SPUUserDriver — it constructs SPUStandardUserDriver
/// internally. We need that injection to override exactly two
/// surfaces of Sparkle's stock UI (see PhotoXUserDriver) without
/// reinventing the rest.
@MainActor
@Observable
final class UpdaterController {
    enum AvailableUpdate: Equatable {
        case none
        case available(version: String, item: SUAppcastItem)
        case readyToInstall(version: String, item: SUAppcastItem)

        static func == (lhs: AvailableUpdate, rhs: AvailableUpdate) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case let (.available(va, _), .available(vb, _)):       return va == vb
            case let (.readyToInstall(va, _), .readyToInstall(vb, _)): return va == vb
            default: return false
            }
        }
    }

    /// What the pill should reflect right now. `nil` everywhere
    /// else means the toolbar item renders nothing.
    private(set) var availableUpdate: AvailableUpdate = .none

    /// Sparkle's reply closure from `showUpdateFoundWithAppcastItem`.
    /// Invoked with `.install` when the user clicks the
    /// `.available` pill. Cleared once invoked so the closure can't
    /// re-fire — Sparkle expects each reply exactly once.
    private var pendingDownloadReply: ((SPUUserUpdateChoice) -> Void)?

    /// Sparkle's reply closure from `showReadyToInstallAndRelaunch`.
    /// Invoked with `.install` after the user OKs the restart
    /// alert; cleared once invoked.
    private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?

    /// Mirrors Sparkle's KVO property so the menu Check-for-Updates
    /// button can disable itself when an update is in flight.
    var canCheckForUpdates: Bool

    private let userDriver: PhotoXUserDriver
    private let updater: SPUUpdater
    /// Strong reference — SPUUpdater holds the delegate weakly, so
    /// it must outlive the updater.
    private let updaterDelegate: UpdaterDelegate
    /// Same story for the standard user driver's delegate (which we
    /// implement here to flip Sparkle's "gentle reminders" mode on).
    private let standardDriverDelegate: StandardDriverDelegate
    private let standardDriver: SPUStandardUserDriver
    private var observation: NSKeyValueObservation?

    init() {
        // DEBUG / `just dev` skips Sparkle wiring entirely. The DEV
        // bundle ID is different from production's, so checking the
        // prod appcast would either no-op (mismatched IDs) or worse,
        // prompt to "downgrade" the dev build to the latest Release.
        // The menu item stays visible but disabled because
        // canCheckForUpdates remains false.
        #if DEBUG
        let startingUpdater = false
        #else
        let startingUpdater = true
        #endif

        let updaterDelegate = UpdaterDelegate()
        let standardDriverDelegate = StandardDriverDelegate()
        let standardDriver = SPUStandardUserDriver(
            hostBundle: Bundle.main,
            delegate: standardDriverDelegate
        )
        let userDriver = PhotoXUserDriver(inner: standardDriver)
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: updaterDelegate
        )

        self.updaterDelegate = updaterDelegate
        self.standardDriverDelegate = standardDriverDelegate
        self.standardDriver = standardDriver
        self.userDriver = userDriver
        self.updater = updater
        self.canCheckForUpdates = updater.canCheckForUpdates

        userDriver.controller = self

        self.observation = updater.observe(
            \.canCheckForUpdates, options: [.new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }

        if startingUpdater {
            do {
                try updater.start()
            } catch {
                // Sparkle's start() can fail if e.g. the bundle is
                // unsigned or the feed URL is missing. We log + go
                // dark; canCheckForUpdates stays false so the menu
                // entry shows but is disabled.
                Log.app.error("SPUUpdater.start failed: \(String(describing: error), privacy: .public)")
            }

            // Force policy on every launch — these persist in user
            // defaults, so we rewrite to keep them in sync with the
            // documented policy regardless of any prior toggling.
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = false
            // Defensive wipe of any pre-existing skip-version lock
            // from the old (pre-pill) flow. With the pill design the
            // user can't skip; this guarantees no stale skip
            // permanently silences a version.
            UserDefaults.standard.removeObject(forKey: "SUSkippedVersion")

            // Immediate background check on launch in addition to
            // the scheduled cadence, so the user doesn't wait up to
            // 5 min on first launch.
            updater.checkForUpdatesInBackground()
        }
    }

    /// Manual menu trigger. With the pill design there's nothing
    /// to clear on the controller side — Sparkle drives back through
    /// the user driver and re-populates `availableUpdate`.
    /// `resetUpdateCycle` + the cache-buster query param (see
    /// UpdaterDelegate) ensure no CDN cache hit.
    func checkForUpdates() {
        updater.resetUpdateCycle()
        updater.checkForUpdates()
    }

    // MARK: - PhotoXUserDriver callbacks

    /// Called by the user driver when Sparkle has found an update.
    func captureAvailable(item: SUAppcastItem,
                           version: String,
                           reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // If we somehow have a stale download reply (e.g. the user
        // dismissed the pill click via the standard sheet earlier
        // in the session and Sparkle re-detected), reply to the
        // previous one with `.dismiss` so Sparkle doesn't hang
        // waiting on it.
        pendingDownloadReply?(.dismiss)
        pendingDownloadReply = reply
        availableUpdate = .available(version: version, item: item)
    }

    /// Called by the user driver when Sparkle has finished
    /// downloading and is ready to install on quit.
    func captureReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingInstallReply?(.dismiss)
        pendingInstallReply = reply
        // Preserve the version we already showed the user; if the
        // current state is `.available(version, item)` we keep the
        // same labels. If somehow we ended up here without a prior
        // `.available` (Sparkle re-invoked us in an unexpected
        // order), leave state alone — the pill won't render until
        // the next `captureAvailable` arrives. Sparkle's stashed
        // reply still drives a real restart later.
        if case let .available(version, item) = availableUpdate {
            availableUpdate = .readyToInstall(version: version, item: item)
        }
    }

    /// Pill click handler for the `.available` state. Replays
    /// Sparkle's stashed reply with `.install` — Sparkle's stock
    /// download UI takes it from here.
    func userClickedAvailable() {
        guard let reply = pendingDownloadReply else { return }
        pendingDownloadReply = nil
        reply(.install)
    }

    /// Pill click handler for the `.readyToInstall` state. Asks
    /// the user to confirm the restart via NSAlert (with the
    /// shoot-will-reopen reassurance), stashes the current shoot
    /// URL via `PendingReopenStore` so `PhotoXApp.bootstrap` can
    /// resume it on relaunch, then replays Sparkle's stashed reply
    /// with `.install`.
    func confirmRestartAndInstall(currentShootURL: URL?) {
        guard case let .readyToInstall(version, _) = availableUpdate,
              let reply = pendingInstallReply else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Restart PhotoX to install \(version)?"
        if currentShootURL != nil {
            alert.informativeText = "Your current shoot will reopen automatically once the install finishes."
        } else {
            alert.informativeText = "PhotoX will quit, install the update, and relaunch."
        }
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else {
            // Leave state as .readyToInstall so the pill stays put
            // and the user can confirm later.
            return
        }
        if let url = currentShootURL {
            PendingReopenStore.set(url: url)
        } else {
            PendingReopenStore.clear()
        }
        pendingInstallReply = nil
        reply(.install)
    }

    // MARK: - Pill model

    struct PillContent {
        let icon: String
        let label: String
        let help: String
        let onTap: () -> Void
    }

    /// What the toolbar pill should render. `nil` → hide.
    /// Re-evaluated whenever `availableUpdate` changes.
    func pillContent(currentShootURL: URL?) -> PillContent? {
        switch availableUpdate {
        case .none:
            return nil
        case .available(let version, _):
            return PillContent(
                icon: "arrow.down.circle.fill",
                label: "Update available: \(version)",
                help: "Click to install \(version). PhotoX will download then prompt before restarting.",
                onTap: { [weak self] in self?.userClickedAvailable() }
            )
        case .readyToInstall(let version, _):
            return PillContent(
                icon: "arrow.clockwise.circle.fill",
                label: "Restart to install: \(version)",
                help: "Click to restart and finish installing \(version).",
                onTap: { [weak self] in
                    self?.confirmRestartAndInstall(currentShootURL: currentShootURL)
                }
            )
        }
    }
}

/// Sparkle delegate. Sole responsibility now: inject a per-request
/// timestamp into the appcast URL so each check bypasses CDN/HTTP
/// caches (GitHub Raw is fronted by Fastly). The old session-scoped
/// "user dismissed this version" state is gone — the pill design
/// makes it unnecessary (the pill stays put across background
/// re-checks of the same version, and Sparkle's
/// gentle-reminders mode prevents modal nagging).
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func feedParameters(for updater: SPUUpdater,
                                    sendingSystemProfile sendingProfile: Bool)
        -> [[String: String]]
    {
        let t = String(Int(Date().timeIntervalSince1970))
        return [["key": "_t", "value": t]]
    }
}

/// Tells Sparkle to use its "gentle scheduled update reminders"
/// mode so the standard modal sheet stays suppressed even when an
/// update is found in the background. Our user driver then routes
/// the discovery into the titlebar pill.
final class StandardDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // false = don't show the standard modal; just call into our
        // user driver (which sets the pill).
        false
    }
}
