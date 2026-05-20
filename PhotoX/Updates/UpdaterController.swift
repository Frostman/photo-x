import AppKit
import Foundation
import os
import Sparkle

/// Sparkle 2 wrapper that surfaces auto-update state through a
/// passive titlebar pill instead of Sparkle's modal sheet during
/// background polls.
///
/// **Why the stock `SPUStandardUpdaterController` and not a custom
/// `SPUUserDriver`?** Sparkle's gentle-reminders mechanism only
/// fires when `SPUStandardUserDriver` is the active driver — wrapping
/// it broke both the gentle-reminders hook (pill never appeared)
/// and Sparkle's internal lifecycle (extraction hung after download).
/// We use Sparkle's documented `SPUStandardUserDriverDelegate` path
/// instead. Trade-off: the standard "Update Available" modal Sparkle
/// shows on click-from-pill keeps its Skip Version button — fine.
///
/// Flow:
///
///  1. Sparkle's background poll (every 5 min) finds an update and
///     queries `standardUserDriverShouldHandleShowingScheduledUpdate`.
///     We return false → Sparkle suppresses its modal.
///  2. Sparkle then calls `standardUserDriverWillHandleShowingUpdate`
///     with `handleShowingUpdate=false`, which is our signal to flip
///     `availableUpdate` to `.available(...)` and let the pill render.
///  3. The user clicks the pill → `checkForUpdates()` re-enters
///     Sparkle on the user-initiated path. Sparkle shows its
///     standard "Update Available" sheet (with Skip / Later / Install).
///  4. User clicks Install → Sparkle's standard download +
///     install-and-relaunch sheets run.
///  5. When the user confirms relaunch, `updaterWillRelaunchApplication`
///     fires — we capture the currently-open shoot folder URL via
///     `PendingReopenStore` so `PhotoXApp.bootstrap()` can resume
///     the same shoot on the next launch.
@MainActor
@Observable
final class UpdaterController {
    enum AvailableUpdate: Equatable {
        case none
        case available(version: String, item: SUAppcastItem)

        static func == (lhs: AvailableUpdate, rhs: AvailableUpdate) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case let (.available(va, _), .available(vb, _)): return va == vb
            default: return false
            }
        }
    }

    private(set) var availableUpdate: AvailableUpdate = .none

    /// Mirrors Sparkle's KVO property so the menu Check-for-Updates
    /// button can disable itself while a check is in flight.
    var canCheckForUpdates: Bool

    /// Closure the host sets so we can capture the currently-open
    /// shoot folder URL right before Sparkle quits the app for the
    /// install. Optional — nil means no reopen will be staged.
    var shootURLProvider: (() -> URL?)?

    private let updater: SPUStandardUpdaterController
    /// Strong refs — Sparkle holds delegates weakly.
    private let updaterDelegate: UpdaterDelegate
    private let userDriverDelegate: UserDriverDelegate
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
        let userDriverDelegate = UserDriverDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: userDriverDelegate
        )
        self.updater = controller
        self.updaterDelegate = updaterDelegate
        self.userDriverDelegate = userDriverDelegate
        self.canCheckForUpdates = controller.updater.canCheckForUpdates

        // Wire delegates back to self so they can flip our state.
        updaterDelegate.controller = self
        userDriverDelegate.controller = self

        self.observation = controller.updater.observe(
            \.canCheckForUpdates, options: [.new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }

        #if !DEBUG
        // Force policy on every launch — these persist in user
        // defaults, so we rewrite to keep them in sync with the
        // documented policy regardless of any prior toggling.
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false
        // Immediate background check on launch in addition to the
        // scheduled cadence so the user doesn't wait up to 5 min on
        // first launch.
        controller.updater.checkForUpdatesInBackground()
        #endif
    }

    /// Menu trigger. Resets Sparkle's cycle + cache-bust query
    /// param (see `UpdaterDelegate.feedParameters`) so a manual
    /// click always fetches fresh.
    func checkForUpdates() {
        updater.updater.resetUpdateCycle()
        updater.checkForUpdates(nil)
    }

    /// Pill click handler. Re-enters Sparkle as a user-initiated
    /// check — Sparkle's standard "Update Available" sheet opens
    /// with Install / Skip / Later / Release Notes. From there the
    /// standard download + install/relaunch flow takes over.
    func userClickedAvailable() {
        checkForUpdates()
    }

    // MARK: - Delegate callbacks

    /// Called by `UpdaterDelegate.updaterWillRelaunchApplication`.
    /// Capture the currently-open shoot URL so the post-install
    /// bootstrap can resume it.
    func captureShootForReopen() {
        if let url = shootURLProvider?() {
            PendingReopenStore.set(url: url)
        } else {
            PendingReopenStore.clear()
        }
    }

    /// Called by `UserDriverDelegate.standardUserDriverWillHandleShowingUpdate`
    /// when Sparkle is about to (or in our case, is about to skip)
    /// showing an update modal. We use this as the signal to set
    /// the pill state.
    func updateDiscovered(item: SUAppcastItem) {
        let version = "v\(item.displayVersionString)"
        availableUpdate = .available(version: version, item: item)
    }

    // MARK: - Pill model

    struct PillContent {
        let icon: String
        let label: String
        let help: String
        let onTap: () -> Void
    }

    /// What the toolbar pill should render. `nil` → hide.
    func pillContent(currentShootURL: URL?) -> PillContent? {
        switch availableUpdate {
        case .none:
            return nil
        case .available(let version, _):
            return PillContent(
                icon: "arrow.down.circle.fill",
                label: "Update available: \(version)",
                help: "Click to open the standard Sparkle update sheet.",
                onTap: { [weak self] in self?.userClickedAvailable() }
            )
        }
    }
}

/// Sparkle's updater-side delegate. Two responsibilities:
///
/// 1. Inject a per-request timestamp into the appcast URL so each
///    check bypasses any CDN/HTTP cache (GitHub Raw is fronted by
///    Fastly).
/// 2. Hook `updaterWillRelaunchApplication` so we can save the
///    currently-open shoot folder URL before Sparkle quits the app
///    for the install — `PhotoXApp.bootstrap` reads it on relaunch.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var controller: UpdaterController?

    nonisolated func feedParameters(for updater: SPUUpdater,
                                    sendingSystemProfile sendingProfile: Bool)
        -> [[String: String]]
    {
        let t = String(Int(Date().timeIntervalSince1970))
        return [["key": "_t", "value": t]]
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Bounce to main actor so we can read SwiftUI state.
        Task { @MainActor [weak controller] in
            controller?.captureShootForReopen()
        }
    }
}

/// Sparkle's user-driver-side delegate. Opts into gentle-reminders
/// mode so Sparkle suppresses its modal during background polls,
/// and notifies us of the suppressed update so we can render the
/// pill instead.
final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    weak var controller: UpdaterController?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Returning false suppresses Sparkle's standard modal for
    /// scheduled (background) checks. User-initiated checks still
    /// go through the standard modal path.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// Called when Sparkle is about to either show or quietly
    /// handle an update. `handleShowingUpdate=false` for the
    /// gentle case (we suppressed the modal) — that's our signal
    /// to set the pill state.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Only set the pill for the background, suppressed case.
        // User-initiated checks let Sparkle's standard modal drive.
        guard !handleShowingUpdate else { return }
        Task { @MainActor [weak controller] in
            controller?.updateDiscovered(item: update)
        }
    }
}
