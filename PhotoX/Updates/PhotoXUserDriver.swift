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
            Log.app.notice("update: install clicked → reply(.install)")
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
            Log.app.notice("update: cancel at Available — popup closed, reply held")
            popup.close()
        case .downloading, .extracting:
            // Hand cancel to Sparkle; it will fire
            // dismissUpdateInstallation which closes the popup.
            Log.app.notice("update: cancel during download → cancel block")
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
            Log.app.notice("update: openCachedOffer — no pendingItem")
            return
        }
        Log.app.notice("update: openCachedOffer v\(item.displayVersionString, privacy: .public)")
        popup.model.resetForNewUpdate(
            newVersion: item.displayVersionString,
            currentVersion: Self.currentVersion()
        )
        if let inline = item.itemDescription, !inline.isEmpty {
            popup.model.releaseNotesHTML = Data(inline.utf8)
        }
        popup.show()
    }

    var hasPendingOffer: Bool { pendingItem != nil }

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
        Log.app.notice("update: showUserInitiatedUpdateCheck — appcast fetch in flight")
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
        Log.app.notice("update: showUpdateFound v\(appcastItem.displayVersionString, privacy: .public) userInitiated=\(state.userInitiated, privacy: .public)")

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
            Log.app.notice("update: user-initiated → opening popup")
            popup.model.resetForNewUpdate(
                newVersion: appcastItem.displayVersionString,
                currentVersion: Self.currentVersion()
            )
            if let inline = appcastItem.itemDescription, !inline.isEmpty {
                popup.model.releaseNotesHTML = Data(inline.utf8)
            }
            popup.show()
        } else {
            // Background poll: pill is enough. Popup opens on pill
            // click via `openCachedOffer()`.
            Log.app.notice("update: background poll → pill set, reply held")
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        popup.model.releaseNotesHTML = downloadData.data
        popup.model.releaseNotesFailed = false
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        Log.app.error("update release notes fetch failed: \(String(describing: error), privacy: .public)")
        popup.model.releaseNotesFailed = true
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let userInitiated = controller?.consumePendingUserInitiated() ?? false
        Log.app.notice("update: showUpdateNotFoundWithError userInitiated=\(userInitiated, privacy: .public) error=\(String(describing: error), privacy: .public)")
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
        Log.app.notice("update: auto-confirming install + relaunch")
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
        Log.app.notice("update: dismissUpdateInstallation — clearing popup + pill")
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

    // MARK: - DEBUG fake-popup harness
    //
    // Sparkle is disabled in DEBUG (UpdaterController init returns
    // early), so the real lifecycle never fires in dev. This entry
    // point lets us drive the popup through every stage from a
    // DEBUG-only menu command, so we can verify the UI in `just dev`
    // without shipping a release.

    #if DEBUG
    func debugDriveFakePopup() {
        popup.model.resetForNewUpdate(
            newVersion: "0.999.0",
            currentVersion: Self.currentVersion()
        )
        popup.model.releaseNotesHTML = Data("""
        <h3>What's new in this fake update</h3>
        <ul>
          <li>Custom popup verification</li>
          <li>Two buttons only: Cancel / Install</li>
          <li>Walks through stages on a timer</li>
        </ul>
        """.utf8)
        // Synthesize stashed callbacks so the buttons drive the stage
        // transitions without going through Sparkle.
        availableReply = { [weak self] choice in
            guard choice == .install else { return }
            self?.debugSimulateLifecycle()
        }
        cancelDownload = { [weak self] in self?.dismissUpdateInstallation() }
        popup.show()
    }

    private func debugSimulateLifecycle() {
        // Drive Available → Downloading → Extracting → Installing →
        // close, paced by short timers so we can watch the popup
        // transition. The driver is MainActor; Task.sleep keeps us
        // on the actor when resumed.
        Task { @MainActor in
            self.showDownloadInitiated(cancellation: { })
            self.showDownloadDidReceiveExpectedContentLength(80_000_000)
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(120))
                self.showDownloadDidReceiveData(ofLength: 4_000_000)
            }
            self.showDownloadDidStartExtractingUpdate()
            for i in 1...10 {
                try? await Task.sleep(for: .milliseconds(120))
                self.showExtractionReceivedProgress(Double(i) / 10.0)
            }
            self.showInstallingUpdate(withApplicationTerminated: false,
                                      retryTerminatingApplication: { })
            try? await Task.sleep(for: .milliseconds(800))
            self.dismissUpdateInstallation()
        }
    }
    #endif
}
