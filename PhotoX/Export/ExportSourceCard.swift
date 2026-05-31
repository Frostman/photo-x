import AppKit
import SwiftUI

/// Read-only counterpart to `ExportDestinationRow`. Lives
/// in the new "Source" section between Project name and
/// Destinations on the Export tab. Mirrors the destination
/// card's chrome (padding, rounded background, overlay
/// border, monospaced path label) but strips every
/// interactive control — no buttons, no toggles, no filter
/// chips. Only renders:
///
/// - The shoot's source folder path.
/// - The planning-phase progress bar
///   (`runner.planningProgress?.source.fraction`) while
///   source-side stats are in flight.
/// - Any source-side read errors recorded by the planning
///   task (path-not-found, permission denied, etc.).
///
/// The card is always present when the Export tab is
/// visible — even between exports it shows the source path
/// so the user can confirm the shoot they're about to
/// export. The progress + errors are transient.
struct ExportSourceCard: View {
    let sourceURL: URL?
    let runner: ExportRunner

    private var pathLabel: String {
        guard let url = sourceURL else { return "— no folder open —" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(pathLabel)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                    .help(sourceURL?.path ?? "")
                Spacer()
            }
            if let progress = runner.planningProgress?.source, progress.total > 0 {
                planningRow(progress)
            }
            if let errors = runner.planningProgress?.source.errors, !errors.isEmpty {
                errorRow(errors)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func planningRow(_ progress: TaskProgress) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            Text("\(progress.done)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorRow(_ errors: [(URL, String)]) -> some View {
        // Same compact "first 3 + …" treatment as the
        // destination card's per-file errors so the two
        // surfaces read as the same kind of feedback.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(errors.prefix(3).enumerated()), id: \.offset) { _, pair in
                let (url, message) = pair
                Text("\(url.lastPathComponent): \(message)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(url.path)\n\(message)")
            }
            if errors.count > 3 {
                Text("+ \(errors.count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}
