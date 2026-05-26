import AppKit
import SwiftUI

/// The contents of the Usage Stats window. Reads counters via the
/// `@Bindable` shim around `UsageMetrics` so any in-memory record*
/// call (e.g. the user navigates a photo while the window is open)
/// re-renders the grid live.
struct StatsView: View {
    // @Observable triggers view re-evaluation on any tracked
    // property read automatically — no @Bindable wrapper needed,
    // and dropping it lets us read `lastUploadedAt` (private(set))
    // which Bindable's dynamic-member subscript refuses.
    var metrics: UsageMetrics
    /// Invoked when the user clicks "Send now" or — kept as the
    /// extension point — when the periodic loop ticks. The owning
    /// window controller passes `{ await state.uploadTelemetryNow() }`
    /// so the button drives the same code path as the auto-flush.
    var onSendNow: () async -> Void = {}
    /// Invoked by the Esc key. The owning window controller passes
    /// `{ self.close() }` so Esc dismisses the floating window.
    var onClose: () -> Void = {}

    @AppStorage(SettingsKey.telemetryEnabled, store: AppDefaults.shared)
    private var telemetryEnabled = SettingsKey.Defaults.telemetryEnabled

    @State private var isSending = false

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
                Button {
                    Task {
                        isSending = true
                        await onSendNow()
                        isSending = false
                    }
                } label: {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Send now")
                    }
                }
                .disabled(!telemetryEnabled || isSending)
                .help(telemetryEnabled
                      ? "Upload the current totals to PostHog Cloud now."
                      : "Enable telemetry in Settings → Privacy first.")
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
                if let last = metrics.lastUploadedAt {
                    Text("·  last sent \(Self.formatRelative(from: last))")
                        .foregroundStyle(.secondary)
                } else if telemetryEnabled {
                    Text("·  never sent")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if telemetryEnabled {
                Text("Counters upload every \(TelemetryConfig.uploadIntervalDescription) (and on quit). Click \u{201C}Send now\u{201D} below to upload immediately.")
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
        f.dateTimeStyle = .named
        return f
    }()

    /// Wrap RelativeDateTimeFormatter with a "just now" guard for
    /// sub-minute deltas. Without it the formatter says "in 0 sec"
    /// the instant after a successful send (date == now), which
    /// reads as a bug. Also clamps tiny clock drift in the future
    /// direction to "just now" rather than "in 1 sec".
    private static func formatRelative(from date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
