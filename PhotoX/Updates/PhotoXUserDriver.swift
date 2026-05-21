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
            reply(.install)
        }
    }

    private func userClickedCancel() {
        switch popup.model.stage {
        case .available:
            if let reply = availableReply {
                availableReply = nil
                reply(.dismiss)
            }
            popup.close()
        case .downloading, .extracting:
            // Hand cancel to Sparkle; it will fire
            // dismissUpdateInstallation which closes the popup.
            cancelDownload?()
            cancelDownload = nil
        case .installing:
            // App is about to quit — Cancel is hidden in the view.
            break
        }
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
        // Always update the controller's pill regardless of whether
        // this is user-initiated or a background poll — that way the
        // pill reflects the latest known version even if the user
        // closes the popup without acting.
        controller?.updateDiscovered(item: appcastItem)

        if !state.userInitiated {
            // Background poll: don't open the popup. Release Sparkle
            // immediately so the next poll can run.
            reply(.dismiss)
            return
        }

        // User-initiated: open the popup with the appcast info.
        cancelCheck = nil
        availableReply = reply
        popup.model.resetForNewUpdate(
            newVersion: appcastItem.displayVersionString,
            currentVersion: Self.currentVersion()
        )
        // If the appcast embedded release notes inline as the
        // <description>, surface them right away. Sparkle will also
        // call `showUpdateReleaseNotesWithDownloadData:` if the
        // appcast linked them via <releaseNotesLink>.
        if let inline = appcastItem.itemDescription, !inline.isEmpty {
            popup.model.releaseNotesHTML = Data(inline.utf8)
        }
        popup.show()
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
        // For user-initiated checks we surface a "you're up to date"
        // alert. Background polls finish silently. We use the
        // popup's stage as a proxy for whether a session was active.
        let userInitiated = controller?.consumePendingUserInitiated() ?? false
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
        availableReply = nil
        cancelDownload = nil
        cancelCheck = nil
        retryTerminate = nil
        popup.close()
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
