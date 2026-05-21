import Foundation
import Observation

/// State machine + progress data for the custom self-update popup.
/// Owned by `PhotoXUserDriver`; mutated as Sparkle's lifecycle
/// methods fire; read by `UpdateInstallView` to render the current
/// stage. MainActor-isolated because every mutation hops back to the
/// main actor from a Sparkle callback before touching the model.
@MainActor
@Observable
final class UpdateInstallViewModel {
    enum Stage: Sendable, Hashable {
        case available     // Update found; user can Install or Cancel
        case downloading   // Sparkle downloading the package
        case extracting    // Sparkle extracting the downloaded archive
        case installing    // App about to terminate / installing
    }

    var stage: Stage = .available

    /// Version offered by the appcast (e.g. "0.X.0").
    var newVersion: String = ""

    /// Current install version (read from `Bundle.main`).
    var currentVersion: String = ""

    /// HTML data for release notes (rendered in WKWebView). Nil while
    /// release notes are still being fetched.
    var releaseNotesHTML: Data?

    /// True when Sparkle reported the release-notes fetch failed.
    var releaseNotesFailed: Bool = false

    /// Total expected download size in bytes. Zero until Sparkle
    /// reports the expected content length.
    var totalBytes: UInt64 = 0

    /// Bytes received so far. Reset to zero when stage transitions
    /// back to `.available` for a new update.
    var receivedBytes: UInt64 = 0

    /// Extraction progress (0.0 ... 1.0).
    var extractionProgress: Double = 0

    /// Bound by the view to disable buttons during transient handoff
    /// (e.g. between Install being clicked and Sparkle reporting
    /// `showDownloadInitiated`).
    var actionsEnabled: Bool = true

    /// 0.0 ... 1.0 progress for the download stage; falls back to 0
    /// before Sparkle reports a content length.
    var downloadFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(receivedBytes) / Double(totalBytes))
    }

    /// True when the progress bar should render in indeterminate
    /// mode — either right before the first byte lands during
    /// download, or during the brief "extracting" transition.
    var progressIndeterminate: Bool {
        switch stage {
        case .available, .installing: return false
        case .downloading: return totalBytes == 0
        case .extracting:  return extractionProgress <= 0
        }
    }

    /// Right-aligned secondary text shown next to the progress bar.
    var progressLabel: String {
        switch stage {
        case .available:
            return ""
        case .downloading:
            if totalBytes > 0 {
                return "\(Self.format(bytes: receivedBytes)) of \(Self.format(bytes: totalBytes))"
            } else {
                return "Starting download…"
            }
        case .extracting:
            return "Preparing update…"
        case .installing:
            return "Installing — PhotoX will relaunch…"
        }
    }

    /// Reset for a fresh "available" state for a new update.
    func resetForNewUpdate(newVersion: String, currentVersion: String) {
        stage = .available
        self.newVersion = newVersion
        self.currentVersion = currentVersion
        releaseNotesHTML = nil
        releaseNotesFailed = false
        totalBytes = 0
        receivedBytes = 0
        extractionProgress = 0
        actionsEnabled = true
    }

    static func format(bytes: UInt64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useKB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: Int64(bytes))
    }
}
