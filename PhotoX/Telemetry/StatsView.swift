import AppKit
import SwiftUI

/// The contents of the Usage Stats window. Reads counters via the
/// `@Bindable` shim around `UsageMetrics` so any in-memory record*
/// call (e.g. the user navigates a photo while the window is open)
/// re-renders the grid live.
struct StatsView: View {
    @Bindable var metrics: UsageMetrics
    /// Invoked by the Esc key. The owning window controller passes
    /// `{ self.close() }` so Esc dismisses the floating window
    /// instead of triggering the destructive "Reset stats" path
    /// (which previously stole `.cancelAction`).
    var onClose: () -> Void = {}

    @AppStorage(SettingsKey.telemetryEnabled, store: AppDefaults.shared)
    private var telemetryEnabled = SettingsKey.Defaults.telemetryEnabled

    @State private var showResetConfirm = false

    var body: some View {
        let total = metrics.total
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            counterGrid(total)
            Divider()
            telemetryStatus
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Reset stats…") {
                    showResetConfirm = true
                }
            }
        }
        // Hidden Esc trap — fires onClose() without surfacing a
        // visible button. Has to live INSIDE the view hierarchy
        // (not on the window) so SwiftUI's key-equivalent dispatch
        // routes through it; sized 0×0 + .accessibilityHidden so
        // it never appears in the layout or VoiceOver.
        .background {
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 420)
        .alert("Reset all usage stats?",
               isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task { await metrics.reset() }
            }
        } message: {
            Text("This zeroes every counter and writes the zeros to disk. The anonymous telemetry ID is NOT reset — re-enabling telemetry later stitches the new uploads to the same identity.")
        }
    }

    // MARK: - subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PhotoX Usage Stats")
                .font(.title2.bold())
            Text("Since \(Self.dayFormatter.string(from: metrics.firstLaunchAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func counterGrid(_ total: UsageMetrics.Counters) -> some View {
        Grid(alignment: .leading,
             horizontalSpacing: 16, verticalSpacing: 8) {
            counterRow("App opens",           total.appOpens)
            counterRow("Shoots opened",       total.shootsOpened)
            counterRow("Photos seen",         total.photosSeen)
            counterRow("Ratings / labels set", total.scoresSet)
            counterRow("Exports completed",   total.exportsCompleted)
            counterRow("Images exported",     total.imagesExported)
        }
    }

    @ViewBuilder
    private func counterRow(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.primary)
            Text(Self.numberFormatter.string(from: NSNumber(value: value))
                 ?? String(value))
                .font(.body.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var telemetryStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Telemetry")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(telemetryEnabled ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(telemetryEnabled ? "Enabled" : "Disabled")
                if telemetryEnabled, let last = metrics.lastPersistedAt {
                    Text("·  last persisted \(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if telemetryEnabled {
                Text("Counters upload every \(TelemetryConfig.uploadIntervalDescription) (and on quit).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Toggle on in Settings → Privacy to send counters to PostHog Cloud (uploads every \(TelemetryConfig.uploadIntervalDescription)). Counters are saved locally every \(TelemetryConfig.localPersistIntervalDescription) regardless.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - formatters

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
