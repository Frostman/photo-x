import SwiftUI

/// Toolbar segmented control that doubles as the workspace-mode
/// switch (View ↔ Export) and the export-progress display. Sits
/// in the right-side `.primaryAction` cluster next to the
/// failed-writes pill.
///
/// The Export tab's label is dynamic across three states:
/// - Idle: doc icon + "Export".
/// - Running: spinner + "Export N% · ETA".
/// - Finished (briefly): doc icon + "Export: <outcome> Nm ago".
///
/// Tab switching is also bound to ⌘1 / ⌘2 via the View menu.
struct WorkspaceTabPicker: View {
    @Bindable var state: ViewerState
    @Binding var mode: WorkspaceMode
    @State private var runner = ExportRunner.shared

    var body: some View {
        // Refresh once a minute so the "Nm ago" finished label keeps
        // ticking even when nothing else triggers a re-render.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 0) {
                tab(.view,
                    icon: "photo.stack",
                    label: { Text("View").font(.caption.bold()) },
                    help: "Show the viewer (canvas, sidebar, filmstrip) — ⌘1")

                Divider().frame(height: 14)

                tab(.export,
                    icon: nil,
                    label: { exportLabel(now: context.date) },
                    help: runner.isRunning
                        ? "Export running — click to open the Export tab (⌘2)"
                        : "Configure and export to destinations (⌘2)")
            }
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .helpAnchor(.workspaceMode)
        .accessibilityIdentifier("toolbar.workspaceMode")
    }

    @ViewBuilder
    private func tab<Label: View>(
        _ target: WorkspaceMode,
        icon: String?,
        @ViewBuilder label: () -> Label,
        help: String
    ) -> some View {
        let isActive = mode == target
        Button {
            mode = target
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption.bold())
                }
                label()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .background(isActive ? Color.accentColor : Color.clear)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Three-state label for the Export tab:
    /// - Running: doc icon + "Export N% · ETA" (matches the old pill).
    /// - Finished recently: doc icon + "Export: <outcome> <ago>".
    /// - Idle: doc icon + "Export".
    @ViewBuilder
    private func exportLabel(now: Date) -> some View {
        if let batch = runner.batchProgress {
            runningLabel(batch)
        } else if let outcome = runner.lastBatchOutcome,
                  let completedAt = runner.lastBatchCompletedAt {
            finishedLabel(outcome: outcome,
                          ago: agoString(from: completedAt, now: now))
        } else {
            idleLabel
        }
    }

    private var idleLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.doc.fill")
                .font(.caption.bold())
            Text("Export").font(.caption.bold())
        }
    }

    private func runningLabel(_ batch: ExportRunner.BatchProgress) -> some View {
        // Mode A (sequential): show CURRENT destination's percent + ETA
        // so the user sees forward motion inside each dest; N/M reveals
        // which dest is in flight.
        // Mode B (shared-read): all destinations interleave per source
        // file, so the batch-wide aggregate is the right number.
        let (pct, eta): (Double, TimeInterval?) = {
            if batch.currentDestinationIndex != nil,
               let current = runner.overallProgress {
                return (current.percent, current.eta)
            }
            return (batch.percent, batch.eta)
        }()

        return HStack(spacing: 6) {
            ProgressView(value: pct)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(mode == .export ? .white : .primary)
            if let idx = batch.currentDestinationIndex, batch.destinationCount > 1 {
                Text("Export \(idx)/\(batch.destinationCount) · \(Int(pct * 100))%")
                    .font(.caption.monospacedDigit().bold())
            } else {
                Text("Export \(Int(pct * 100))%")
                    .font(.caption.monospacedDigit().bold())
            }
            if let eta {
                Text("· \(formattedDuration(eta))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(mode == .export ? .white.opacity(0.85) : .secondary)
            }
        }
    }

    private func finishedLabel(outcome: ExportRunner.BatchOutcome, ago: String) -> some View {
        // Three-tone outcome word: green clean, orange cancelled,
        // red failed. Colour is preserved even when the tab is
        // active (white background would hide subtle differences),
        // so we lighten the green/red slightly for contrast against
        // the accent fill.
        let (word, color): (String, Color) = switch outcome {
        case .done:      ("done",      .green)
        case .cancelled: ("cancelled", .orange)
        case .failed:    ("failed",    .red)
        }
        return HStack(spacing: 4) {
            Image(systemName: "arrow.up.doc.fill")
                .font(.caption.bold())
            Text("Export:").font(.caption.bold())
            Text(word).font(.caption.bold())
                .foregroundStyle(mode == .export ? .white : color)
            Text(ago).font(.caption.monospacedDigit())
                .foregroundStyle(mode == .export ? .white.opacity(0.85) : .secondary)
        }
    }
}
