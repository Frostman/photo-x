import AppKit
import Foundation
import os
import Sparkle

/// Wraps raw `SPUUpdater` with our custom `PhotoXUserDriver`. There
/// is no `SPUStandardUserDriver` and therefore no Sparkle-rendered
/// modal sheet anywhere in the app — every user-facing surface is
/// our own popup (`UpdateInstallWindowController`) or NSAlert.
///
/// **Why a custom user driver this time?** A previous wrapper-style
/// attempt (commit `92472cd`) wrapped `SPUStandardUserDriver` and
/// broke twice: gentle-reminders stopped firing and extraction hung
/// mid-download. The fix from that revert (`8ad0f06`) accepted the
/// 4-button standard sheet to keep updates working. This rewrite
/// takes the other lane — implement `SPUUserDriver` directly, no
/// inner standard driver. Every reply/acknowledgement block in
/// `PhotoXUserDriver` is invoked so Sparkle's state machine never
/// stalls.
///
/// Flow:
///
///  1. Background poll (every 5 min) finds an update →
///     `PhotoXUserDriver.showUpdateFound(...)` with `userInitiated=false`
///     → flip `availableUpdate` to `.available(...)`, immediately
///     `reply(.dismiss)` so Sparkle releases.
///  2. Pill appears in the titlebar. Newer version on next poll →
///     same hook fires with the newer item → pill label updates.
///  3. User clicks pill or menu "Check for Updates" → user-initiated
///     check → `showUpdateFound(...)` with `userInitiated=true` →
///     custom popup opens with version + release notes + Cancel /
///     Install Update.
///  4. Cancel at any stage keeps the pill visible.
///  5. Install Update → Sparkle downloads + extracts; the popup's
///     state transitions render progress in-place. Ready-to-install
///     is auto-confirmed (no second sheet). App quits + relaunches.
///  6. `updaterWillRelaunchApplication` captures the open shoot URL
///     so `PhotoXApp.bootstrap()` can resume it on the next launch.
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

    /// Mirrors `SPUUpdater.canCheckForUpdates` for the menu item.
    /// In DEBUG (Sparkle disabled) we leave this `false` so the
    /// menu reflects that real checks aren't running; the DEBUG
    /// fake-popup menu item is separate and always enabled.
    var canCheckForUpdates: Bool = false

    /// Closure the host sets so we can capture the currently-open
    /// shoot folder URL right before Sparkle quits the app for the
    /// install. Optional — nil means no reopen will be staged.
    var shootURLProvider: (() -> URL?)?

    /// The custom user driver. Always instantiated (even in DEBUG)
    /// so the fake-popup harness can drive it from a menu command.
    let userDriver = PhotoXUserDriver()

    /// Nil in DEBUG — see init for the rationale.
    private let updater: SPUUpdater?
    private let updaterDelegate: UpdaterDelegate?
    private var canCheckObservation: NSKeyValueObservation?
    /// Set on every user-initiated `checkForUpdates()`. The user
    /// driver's `showUpdateNotFoundWithError(...)` consumes it to
    /// decide whether to surface the "you're up to date" alert.
    /// Without this flag, background no-update polls would nag the
    /// user every 5 minutes.
    private var pendingUserInitiated: Bool = false

    init() {
        // Always neutralise any persisted skip — we no longer
        // surface a Skip Version button, so leaving a stale
        // SUSkippedVersion in defaults would silently suppress
        // the very update we want to push.
        Self.clearSkippedVersionDefaults()

        #if DEBUG
        // DEBUG / `just dev` skips Sparkle wiring entirely. The dev
        // bundle ID differs from production's, so checking the prod
        // appcast would either no-op (mismatched IDs) or worse,
        // prompt to "downgrade" the dev build to the latest Release.
        // The DEBUG-only fake-popup menu item is what dev uses to
        // verify the UI.
        self.updater = nil
        self.updaterDelegate = nil
        // Stored properties initialized — now safe to reach `self`.
        userDriver.controller = self
        #else
        let delegate = UpdaterDelegate()
        let sparkle = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: delegate
        )
        self.updater = sparkle
        self.updaterDelegate = delegate
        // Force policy on every launch — these persist in user
        // defaults, so we rewrite to keep them in sync with the
        // documented policy regardless of any prior toggling.
        sparkle.automaticallyChecksForUpdates = true
        sparkle.automaticallyDownloadsUpdates = false
        self.canCheckForUpdates = sparkle.canCheckForUpdates

        // Stored properties initialized — now safe to reach `self`.
        userDriver.controller = self
        delegate.controller = self
        self.canCheckObservation = sparkle.observe(
            \.canCheckForUpdates, options: [.new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }

        do {
            try sparkle.start()
        } catch {
            Log.app.error("SPUUpdater.start failed: \(String(describing: error), privacy: .public)")
        }
        // Immediate background check on launch in addition to the
        // scheduled cadence so the user doesn't wait up to 5 min on
        // first launch.
        sparkle.checkForUpdatesInBackground()
        #endif
    }

    /// Menu trigger + pill click. Fires an immediate user-initiated
    /// check; Sparkle's reply lands in `PhotoXUserDriver.showUpdateFound`
    /// with `state.userInitiated == true`, which opens the popup.
    /// In DEBUG (Sparkle off) this is a no-op.
    func checkForUpdates() {
        pendingUserInitiated = true
        updater?.resetUpdateCycle()
        updater?.checkForUpdates()
    }

    /// Pill click handler. Same path as the menu item.
    func userClickedAvailable() {
        checkForUpdates()
    }

    /// Read + reset the "user initiated this check" flag. Called by
    /// `PhotoXUserDriver.showUpdateNotFoundWithError(...)`.
    func consumePendingUserInitiated() -> Bool {
        let v = pendingUserInitiated
        pendingUserInitiated = false
        return v
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

    /// Called by `PhotoXUserDriver.showUpdateFound(...)` on every
    /// new appcast item — even on background polls — so the pill
    /// always reflects the latest known version.
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
                help: "Click to install or read release notes.",
                onTap: { [weak self] in self?.userClickedAvailable() }
            )
        }
    }

    // MARK: - DEBUG fake popup

    #if DEBUG
    /// Drives `PhotoXUserDriver`'s popup through every stage without
    /// Sparkle. Wired to a DEBUG-only menu command so the popup UI
    /// can be verified in `just dev`.
    func debugShowFakePopup() {
        userDriver.debugDriveFakePopup()
    }
    #endif

    private static func clearSkippedVersionDefaults() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "SUSkippedVersion")
        d.removeObject(forKey: "SUSkippedMinorVersion")
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
        // Bounce to main actor so we can read SwiftUI state. Capture
        // `self` (an NSObject, not actor-isolated) and reach for the
        // MainActor-isolated `controller` property *inside* the closure
        // — capturing it directly in the capture list would access it
        // from this nonisolated context.
        Task { @MainActor [weak self] in
            self?.controller?.captureShootForReopen()
        }
    }
}
