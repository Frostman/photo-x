import Foundation
import Sparkle

/// Thin `SPUUserDriver` adapter that wraps the standard driver and
/// replaces just two surfaces of Sparkle's stock UI:
///
/// - `showUpdateFoundWithAppcastItem:state:reply:` — instead of
///   Sparkle showing its three-button "Install / Skip / Later"
///   sheet, we capture the reply closure on `UpdaterController`,
///   flip `availableUpdate` to `.available(...)`, and let the
///   titlebar pill be the affordance. When the user clicks the pill,
///   `UpdaterController.userClickedAvailable()` invokes the saved
///   reply with `.install`, which kicks off Sparkle's stock
///   download UI (forwarded through this driver verbatim).
///
/// - `showReadyToInstallAndRelaunch:` — same trick: stash the
///   reply, flip the pill to `.readyToInstall(...)`. The user
///   clicks again to confirm restart (via `confirmRestartAndInstall`
///   which surfaces an NSAlert), then we invoke the reply with
///   `.install` and Sparkle quits + installs.
///
/// Every other protocol method forwards to the inner standard
/// driver — download progress, release notes, errors, the "no
/// update available" alert, etc. all keep Sparkle's native UI.
@MainActor
final class PhotoXUserDriver: NSObject, SPUUserDriver {

    private let inner: SPUStandardUserDriver
    weak var controller: UpdaterController?

    init(inner: SPUStandardUserDriver) {
        self.inner = inner
    }

    // MARK: - Overridden methods

    func showUpdateFound(with appcastItem: SUAppcastItem,
                        state: SPUUserUpdateState,
                        reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = "v\(appcastItem.displayVersionString)"
        controller?.captureAvailable(item: appcastItem,
                                      version: version,
                                      reply: reply)
        // Deliberately do not forward — the pill replaces Sparkle's
        // three-button sheet (and removes the Skip button along
        // the way).
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller?.captureReadyToInstall(reply: reply)
        // Deliberately do not forward — the pill is the
        // affordance for the user to confirm restart.
    }

    // MARK: - Forwarded methods

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        inner.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        inner.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        inner.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        inner.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error,
                                      acknowledgement: @escaping () -> Void) {
        inner.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error,
                         acknowledgement: @escaping () -> Void) {
        inner.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        inner.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        inner.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        inner.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        inner.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        inner.showExtractionReceivedProgress(progress)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        inner.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
                                           acknowledgement: @escaping () -> Void) {
        inner.showUpdateInstalledAndRelaunched(relaunched,
                                                acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        inner.showUpdateInFocus()
    }

    func dismissUpdateInstallation() {
        inner.dismissUpdateInstallation()
    }
}
