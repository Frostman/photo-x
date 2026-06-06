import SwiftUI

/// Experimental sidebar section: sharpness + aesthetic scores on the
/// displayed frame. Hidden unless `experimentalAIEnabled` is on.
/// Reads from the per-shoot cache (`ViewerState.entryAIScores`); the
/// compute / recompute icon button sits in the section title bar and
/// kicks the work off via `ViewerState`'s shared kick-off path,
/// which is also what the auto-compute hook in `commitDisplayed`
/// calls — manual click and auto-on-display go through the same
/// code so they can't disagree on cache semantics.
struct AIScoresSection: View {
    @Bindable var state: ViewerState

    private var displayedStem: String? { state.displayedEntry?.stem }

    private var cached: AICachedScores? {
        guard let stem = displayedStem else { return nil }
        return state.entryAIScores[stem]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Scores (experimental)")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                titleButton
            }

            if let r = cached {
                VStack(alignment: .leading, spacing: 4) {
                    row("Sharpness", value: r.sharpness)
                    if let aesthetic = r.aesthetic {
                        row("Aesthetic", value: aesthetic)
                    }
                    if let utility = r.utility {
                        Text(utility ? "Utility image (screenshot / document)" : "Photographic")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("sidebar.ai.scores.result")
            } else if displayedStem == nil {
                Text("No image loaded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not yet computed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var titleButton: some View {
        let hasResult = cached != nil
        let symbol = hasResult ? "arrow.clockwise" : "sparkles"
        let help = hasResult
            ? "Recompute scores for the displayed frame"
            : "Compute scores for the displayed frame"
        Button(action: recompute) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(displayedStem == nil)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("sidebar.ai.scores.button")
    }

    private func row(_ label: String, value: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            ProgressView(value: value)
                .progressViewStyle(.linear)
            Text(String(format: "%.2f", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func recompute() {
        guard let stem = displayedStem else { return }
        state.kickOffAIScoresCompute(for: stem, force: true)
    }
}
