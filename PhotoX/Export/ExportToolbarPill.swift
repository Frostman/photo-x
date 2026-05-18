import SwiftUI

/// Toolbar button for the Export feature. Two looks:
///
/// - **Idle**: standard pill with folder/upload icon + "Export" label.
/// - **Running**: shows aggregate percent and ETA, doubles as a re-open
///   button for the configuration sheet.
///
/// Designed to sit as the leftmost item in the right-side primaryAction
/// cluster; a divider after this view visually separates it from the
/// rest of the buttons.
struct ExportToolbarPill: View {
    @Bindable var state: ViewerState
    @Binding var showSheet: Bool
    @State private var runner = ExportRunner.shared

    var body: some View {
        // Refresh once a minute so the "Nm ago" label keeps ticking even
        // when nothing else triggers a re-render.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Button {
                showSheet = true
            } label: {
                HStack(spacing: 6) {
                    if let batch = runner.batchProgress {
                        runningLabel(batch)
                    } else if let outcome = runner.lastBatchOutcome,
                              let completedAt = runner.lastBatchCompletedAt {
                        finishedLabel(outcome: outcome,
                                      ago: agoString(from: completedAt, now: context.date))
                    } else {
                        idleLabel
                    }
                }
                // Explicit padding + background keeps the pill shape consistent
                // across all three states. macOS's auto button-style logic
                // collapses small .bordered toolbar items into icon-only chips,
                // which made the idle Export blend with neighbour buttons.
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help(runner.isRunning
                  ? "Export running — click to reopen the window"
                  : "Configure and export to destinations")
        }
    }

    private func finishedLabel(outcome: ExportRunner.BatchOutcome, ago: String) -> some View {
        // Three-tone status: green = clean run, orange = user-cancelled
        // (intentional, possibly partial), red = genuine failure.
        let (word, color): (String, Color) = switch outcome {
        case .done:      ("done",      .green)
        case .cancelled: ("cancelled", .orange)
        case .failed:    ("failed",    .red)
        }
        return HStack(spacing: 4) {
            Image(systemName: "arrow.up.doc")
            Text("Export:").font(.caption.bold())
            Text(word).font(.caption.bold()).foregroundStyle(color)
            Text(ago).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var idleLabel: some View {
        // .unifiedCompact(showsTitle: false) hides Label titles in toolbar
        // items by default — explicitly request titleAndIcon so the word
        // "Export" always sits next to the icon, matching the running
        // label's layout.
        Label("Export", systemImage: "arrow.up.doc")
            .labelStyle(.titleAndIcon)
            .font(.caption.bold())
    }

    private func runningLabel(_ batch: ExportRunner.BatchProgress) -> some View {
        // Mode A (sequential): percent + ETA describe the CURRENT
        //   destination so the user sees movement within each dest; the
        //   N/M label conveys which dest we're on. The batch-wide total
        //   is shown in the sheet's footer.
        // Mode B (shared-read): all destinations interleave per source
        //   file, so the aggregate batch percent + ETA are the right
        //   numbers to surface; no N/M makes sense.
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
                    .foregroundStyle(.secondary)
            }
        }
    }
}
