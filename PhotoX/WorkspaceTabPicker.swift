import SwiftUI

/// Toolbar segmented control that doubles as the workspace-mode
/// switch and the export-progress display. Sits in the right-
/// side `.primaryAction` cluster next to the failed-writes pill.
///
/// One tab per entry in `workspaceTabs` — adding a new tab means
/// appending to that list, no changes here. Most tabs render
/// just icon + title; the Export tab is the only one with a
/// dynamic label, swapping in the running-batch state when
/// available.
///
/// Tab switching also bound to ⌘<n> via the View menu.
struct WorkspaceTabPicker: View {
    @Bindable var state: ViewerState
    @Binding var mode: WorkspaceMode
    private var runner: ExportRunner { state.exportRunner }

    var body: some View {
        // Refresh once a minute so the "Nm ago" finished label keeps
        // ticking even when nothing else triggers a re-render.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 0) {
                ForEach(Array(workspaceTabs.enumerated()), id: \.element.id) { idx, config in
                    if idx > 0 {
                        Divider().frame(height: 14)
                    }
                    tab(config: config, contextDate: context.date)
                }
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
    private func tab(config: WorkspaceTabConfig, contextDate: Date) -> some View {
        let isActive = mode == config.mode
        let isDisabled = config.requiresShoot && state.shoot == nil
        Button {
            mode = config.mode
        } label: {
            HStack(spacing: 4) {
                // Export gets the dynamic running / finished /
                // idle label; other tabs render a static icon +
                // title from the config.
                if config.mode == .export {
                    exportLabel(now: contextDate)
                } else {
                    Image(systemName: config.icon)
                        .font(.caption.bold())
                    Text(config.title)
                        .font(.caption.bold())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .background(isActive ? Color.accentColor : Color.clear)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .opacity(isDisabled ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText(for: config, disabled: isDisabled))
    }

    private func helpText(for config: WorkspaceTabConfig, disabled: Bool) -> String {
        let shortcutSuffix = " — ⌘\(config.shortcut.character)"
        if disabled {
            return "Open a folder first\(shortcutSuffix)"
        }
        if config.mode == .export, runner.isRunning {
            return "Export running — click to open the Export tab\(shortcutSuffix)"
        }
        switch config.mode {
        case .open:
            return "Open a folder of ARW + HIF/JPG pairs\(shortcutSuffix)"
        case .view:
            return "Show the viewer (canvas, sidebar, filmstrip)\(shortcutSuffix)"
        case .export:
            return "Configure and export to destinations\(shortcutSuffix)"
        }
    }

    /// Three-state label for the Export tab:
    /// - Running: spinner + "Export N% · ETA".
    /// - Finished recently: doc icon + "Export: <outcome> Nm ago".
    /// - Idle: doc icon + "Export".
    @ViewBuilder
    private func exportLabel(now: Date) -> some View {
        if runner.planningProgress != nil {
            planningLabel
        } else if let batch = runner.batchProgress {
            runningLabel(batch)
        } else if let outcome = runner.lastBatchOutcome,
                  let completedAt = runner.lastBatchCompletedAt {
            finishedLabel(outcome: outcome,
                          ago: agoString(from: completedAt, now: now))
        } else {
            idleLabel
        }
    }

    private var planningLabel: some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
            Text("Planning…").font(.caption.bold())
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
