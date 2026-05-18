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

    private func runningLabel(_ p: ExportRunner.BatchProgress) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: p.percent)
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text("Export \(Int(p.percent * 100))%")
                .font(.caption.monospacedDigit().bold())
            if let eta = p.eta {
                Text("· \(formattedDuration(eta))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
