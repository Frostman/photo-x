import AppKit
import Foundation
import Sparkle

/// Custom `SPUUserDriver` that drives `UpdateInstallWindowController`'s
/// popup through Sparkle's full update lifecycle. Implements all
/// required methods directly — does NOT wrap `SPUStandardUserDriver`
/// (the previous wrapping attempt in commit 92472cd broke gentle-
/// reminders and stalled extraction).
///
/// Lifecycle (the only user-facing surfaces are the popup window and
/// two NSAlert error dialogs):
///
///   1. Background poll → `showUpdateFound` with `userInitiated=false`
///      → flip controller pill via `updateDiscovered`; immediately
///      `reply(.dismiss)` so Sparkle releases the lock.
///   2. User clicks pill or menu "Check for Updates" → user-initiated
///      check → `showUpdateFound` with `userInitiated=true` → open
///      popup; stash `reply` for the buttons.
///   3. User clicks Install → `reply(.install)` → Sparkle downloads
///      → we update the popup's progress bar via the model.
///   4. Download complete → `showDownloadDidStartExtractingUpdate` →
///      popup transitions to extracting → progress updates via
///      `showExtractionReceivedProgress`.
///   5. Ready to install → `showReadyToInstallAndRelaunch` →
///      AUTO-CONFIRM `reply(.install)` (no second sheet).
///   6. `showInstallingUpdate` → popup transitions to installing →
///      Sparkle terminates the app for the actual install.
///
/// Cancel semantics by stage:
///   - Available → `reply(.dismiss)` → popup closes → pill stays.
///   - Downloading / Extracting → call stashed download-cancel block
///     → Sparkle invokes `dismissUpdateInstallation` → popup closes.
///   - Installing → no Cancel (app is terminating).
@MainActor
final class PhotoXUserDriver: NSObject, SPUUserDriver {
    /// Weak ref back to the controller so we can flip the pill state
    /// and access the bundle version for the popup banner.
    weak var controller: UpdaterController?

    let popup = UpdateInstallWindowController()

    // MARK: - Stashed callbacks
    //
    // Each "show" method that needs a user choice or cancel block
    // hands one in. We hold a reference until either the user makes
    // a choice, the stage transitions, or Sparkle ends the session.

    private var availableReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancelDownload: (() -> Void)?
    private var cancelCheck: (() -> Void)?
    private var retryTerminate: (() -> Void)?

    /// The appcast item Sparkle most recently offered us (background
    /// poll OR user-initiated check). Stashed so the pill click can
    /// re-open the popup without firing a fresh `checkForUpdates()` —
    /// Sparkle's `.dismiss` reply has stickier session memory than the
    /// docs suggest and silently no-ops same-version checks for a
    /// while after, so we keep `availableReply` alive across Cancel
    /// and only consume it on a real Install.
    private(set) var pendingItem: SUAppcastItem?

    override init() {
        super.init()
        popup.onCancel = { [weak self] in self?.userClickedCancel() }
        popup.onInstall = { [weak self] in self?.userClickedInstall() }
    }

    // MARK: - Button handlers (called from the popup)

    private func userClickedInstall() {
        // Disable the button so a double-click doesn't fire reply
        // twice — Sparkle is going to take a moment before
        // `showDownloadInitiated` lands.
        popup.model.actionsEnabled = false
        if let reply = availableReply {
            availableReply = nil
            // pendingItem is also consumed — once download starts there's
            // no "re-open via pill" path; the popup transitions in-place.
            pendingItem = nil
            Log.updateDebug("install clicked → reply(.install)")
            reply(.install)
        }
    }

    private func userClickedCancel() {
        switch popup.model.stage {
        case .available:
            // Just close the popup. Keep `availableReply` + `pendingItem`
            // alive so the pill stays clickable: a later pill click can
            // re-open this same offer and the user can still install.
            // Replying `.dismiss` here would let Sparkle close the session
            // and then silently no-op all future `checkForUpdates()` calls
            // for the same version — that's the bug commit-message-this
            // change fixes.
            Log.updateDebug("cancel at Available — popup closed, reply held")
            popup.close()
        case .downloading, .extracting:
            // Hand cancel to Sparkle; it will fire
            // dismissUpdateInstallation which closes the popup.
            Log.updateDebug("cancel during download → cancel block")
            cancelDownload?()
            cancelDownload = nil
        case .installing:
            // App is about to quit — Cancel is hidden in the view.
            break
        }
    }

    /// Re-open the popup using the most recent stashed offer. Called
    /// by `UpdaterController.userClickedAvailable()` so the pill click
    /// doesn't re-enter Sparkle (which would no-op against a
    /// previously-dismissed same-version offer).
    func openCachedOffer() {
        guard let item = pendingItem else {
            Log.updateDebug("openCachedOffer — no pendingItem")
            return
        }
        Log.updateDebug("openCachedOffer v\(item.displayVersionString)")
        popup.model.resetForNewUpdate(
            newVersion: item.displayVersionString,
            currentVersion: Self.currentVersion()
        )
        populateReleaseNotes(for: item, into: popup.model)
        popup.show()
    }

    var hasPendingOffer: Bool { pendingItem != nil }

    /// True iff the install popup is currently on-screen. Lets
    /// `UpdaterController.handleSupplementaryTick` decide whether
    /// it's safe to swap the pending offer for a newer one without
    /// pulling the rug from under the user.
    var isPopupOpen: Bool { popup.isOpen }

    /// Release the currently-held offer so Sparkle's session ends
    /// and the next `checkForUpdatesInBackground()` can actually
    /// run (otherwise `sessionInProgress` no-ops it). Caller is
    /// responsible for kicking off the new check. We clear every
    /// piece of cached state — pill, popup, reply, pendingItem —
    /// so the brief window before the new `showUpdateFound` lands
    /// is visually consistent (no stale "vOld available" pill).
    func swapForNewerOffer() {
        Log.updateDebug("swapForNewerOffer — releasing held reply")
        // Tell the controller to fire a fresh check once Sparkle's
        // session fully ends — signalled by didFinishUpdateCycleFor
        // delegate hook, NOT by dismissUpdateInstallation (which
        // fires while sessionInProgress is still true, so any
        // checkForUpdatesInBackground() dispatched from inside it
        // gets silently dropped).
        controller?.markPendingProbeRecheck()
        if let reply = availableReply {
            availableReply = nil
            reply(.dismiss)
        }
        pendingItem = nil
        cancelDownload = nil
        cancelCheck = nil
        popup.close()
        controller?.clearAvailableUpdate()
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Never ask the user. We already enable background checks via
        // `automaticallyChecksForUpdates = true` in UpdaterController,
        // so this should typically not fire. If it does, auto-grant
        // and skip system-profile telemetry.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        Log.updateDebug("showUserInitiatedUpdateCheck — appcast fetch in flight")
        // Stash the cancel block. We don't render a "checking…"
        // window — most checks resolve within ~1s and the popup
        // appears directly when the appcast lands.
        cancelCheck = cancellation
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        Log.updateDebug("showUpdateFound v\(appcastItem.displayVersionString) userInitiated=\(state.userInitiated)")

        // Stash the reply + item regardless of who initiated. The
        // pill is set via controller.updateDiscovered. We DON'T reply
        // here — Sparkle's `.dismiss` is sticky and would silently
        // block subsequent same-version checks. The reply stays alive
        // until the user clicks Install in the popup, or Sparkle
        // ends the session itself via `dismissUpdateInstallation`.
        // Trade-off: while the reply is held, Sparkle's scheduled
        // background poll is suppressed, so a brand-new "even newer"
        // version won't surface mid-session — it'll be picked up on
        // the next app launch.
        cancelCheck = nil
        availableReply = reply
        pendingItem = appcastItem
        controller?.updateDiscovered(item: appcastItem)

        if state.userInitiated {
            // User explicitly asked — open the popup immediately.
            Log.updateDebug("user-initiated → opening popup")
            popup.model.resetForNewUpdate(
                newVersion: appcastItem.displayVersionString,
                currentVersion: Self.currentVersion()
            )
            populateReleaseNotes(for: appcastItem, into: popup.model)
            popup.show()
        } else {
            // Background poll: pill is enough. Popup opens on pill
            // click via `openCachedOffer()`.
            Log.updateDebug("background poll → pill set, reply held")
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Only fill in if we have nothing yet — aggregated or inline
        // notes (set during showUpdateFound) outrank a late
        // single-item link fetch.
        guard popup.model.releaseNotesHTML == nil else { return }
        popup.model.releaseNotesHTML = downloadData.data
        popup.model.releaseNotesFailed = false
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        Log.app.error("update release notes fetch failed: \(String(describing: error), privacy: .public)")
        popup.model.releaseNotesFailed = true
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let userInitiated = controller?.consumePendingUserInitiated() ?? false
        Log.updateDebug("showUpdateNotFoundWithError userInitiated=\(userInitiated) error=\(String(describing: error))")
        // For user-initiated checks we surface a "you're up to date"
        // alert. Background polls finish silently.
        if userInitiated {
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            let version = Self.currentVersion()
            alert.informativeText = version.isEmpty
                ? "PhotoX is the latest version available."
                : "PhotoX \(version) is the latest version available."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Log.app.error("updater error: \(String(describing: error), privacy: .public)")
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn't check for updates"
        alert.runModal()
        // Drop any popup state — Sparkle is aborting.
        availableReply = nil
        cancelDownload = nil
        cancelCheck = nil
        popup.close()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        popup.model.stage = .downloading
        popup.model.actionsEnabled = true
        popup.model.totalBytes = 0
        popup.model.receivedBytes = 0
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        popup.model.totalBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        popup.model.receivedBytes &+= length
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        popup.model.stage = .extracting
        popup.model.extractionProgress = 0
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        popup.model.extractionProgress = progress
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // AUTO-CONFIRM. The user already chose Install once; a second
        // "Install and Relaunch?" sheet would just be friction. We
        // log it so a debug session can spot the transition.
        Log.updateDebug("auto-confirming install + relaunch")
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        popup.model.stage = .installing
        popup.model.actionsEnabled = false
        self.retryTerminate = retryTerminatingApplication
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // Usually not hit — the process is already gone. If we get
        // here, ack so Sparkle can clean up; popup is irrelevant now.
        popup.close()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        Log.updateDebug("dismissUpdateInstallation — clearing popup + pill")
        availableReply = nil
        cancelDownload = nil
        cancelCheck = nil
        retryTerminate = nil
        pendingItem = nil
        popup.close()
        // Sparkle ended the session — the offer is no longer
        // actionable (typical reasons: install completed, download
        // failed, user cancelled mid-download). Clear the pill so it
        // doesn't pretend to be clickable.
        controller?.clearAvailableUpdate()
    }

    // MARK: - Helpers

    private static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    /// Surface release notes for `item` into the popup's view model.
    /// Prefers aggregating notes across every appcast item between
    /// the user's current version and the offered target so a
    /// multi-version skip ("v0.220 → v0.225") shows all four
    /// intermediate changelogs. Falls back to the single-item path
    /// if the appcast isn't loaded yet, only one item is in range,
    /// or there are no notes at all.
    ///
    /// Single-item fallback resolution:
    /// - Inline `<description>` → render it.
    /// - `<sparkle:releaseNotesLink>` present (no inline) → leave the
    ///   model in its "Loading…" state; Sparkle will call
    ///   `showUpdateReleaseNotes(with:)` once the fetch finishes.
    /// - Neither present → mark `releaseNotesFailed = true` so the
    ///   popup shows "Release notes are unavailable." instead of
    ///   pretending a fetch is in flight.
    private func populateReleaseNotes(for item: SUAppcastItem,
                                      into model: UpdateInstallViewModel) {
        if let aggregated = aggregatedReleaseNotes(targetItem: item),
           !aggregated.isEmpty {
            model.releaseNotesHTML = Data(aggregated.utf8)
            return
        }
        if let inline = item.itemDescription, !inline.isEmpty {
            model.releaseNotesHTML = Data(inline.utf8)
            return
        }
        if item.releaseNotesURL == nil {
            model.releaseNotesFailed = true
        }
    }

    /// Returns concatenated `<h2>v…</h2>` + per-item notes for every
    /// appcast item in the range (currentVersion, targetVersion],
    /// newest first. Returns nil when the appcast isn't loaded; ""
    /// when only the target item is in range (caller falls back to
    /// single-item rendering); otherwise the assembled HTML.
    private func aggregatedReleaseNotes(targetItem: SUAppcastItem) -> String? {
        guard let appcast = controller?.lastAppcast else { return nil }
        let cmp = SUStandardVersionComparator.default
        let current = Self.currentVersion()
        let target = targetItem.versionString

        let inRange = appcast.items.filter { it in
            let v = it.versionString
            // Skip empty version strings (malformed entry).
            guard !v.isEmpty else { return false }
            // strictly newer than current
            let above = current.isEmpty
                ? true
                : cmp.compareVersion(v, toVersion: current) == .orderedDescending
            // at most target
            let withinTarget = cmp.compareVersion(v, toVersion: target) != .orderedDescending
            return above && withinTarget
        }

        guard inRange.count > 1 else {
            // Only the target itself qualifies — let the single-item
            // path do its usual rendering.
            return ""
        }

        let sorted = inRange.sorted { a, b in
            cmp.compareVersion(a.versionString, toVersion: b.versionString) == .orderedDescending
        }

        var html = ""
        for it in sorted {
            let body: String = {
                if let inline = it.itemDescription, !inline.isEmpty {
                    return inline
                }
                return "<p><em>No release notes for this version.</em></p>"
            }()
            html += "<h2>v\(it.displayVersionString)</h2>\(body)"
        }
        return html
    }
}
