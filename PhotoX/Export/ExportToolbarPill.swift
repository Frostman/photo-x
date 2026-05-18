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
        Button {
            showSheet = true
        } label: {
            if let batch = runner.batchProgress {
                runningLabel(batch)
            } else {
                idleLabel
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 5)
        .help(runner.isRunning
              ? "Export running — click to reopen the window"
              : "Configure and export to destinations")
    }

    private var idleLabel: some View {
        Label("Export", systemImage: "arrow.up.doc")
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
