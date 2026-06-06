import SwiftUI

/// Experimental sidebar section: classification top-K on the
/// displayed frame. Hidden unless `experimentalAIEnabled` is on.
/// Reads from the per-shoot cache (`ViewerState.entryAIKeywords`).
/// Compute path is shared with the auto-compute hook in
/// `commitDisplayed` via `ViewerState.kickOffAIKeywordsCompute`.
struct AIKeywordsSection: View {
    @Bindable var state: ViewerState

    private var displayedStem: String? { state.displayedEntry?.stem }

    private var cached: [AIKeywordLabel]? {
        guard let stem = displayedStem else { return nil }
        return state.entryAIKeywords[stem]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Keywords (experimental)")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                titleButton
            }

            if let labels = cached {
                if labels.isEmpty {
                    Text("No labels above 0.5 confidence.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sidebar.ai.keywords.empty")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(labels) { item in
                            HStack {
                                Text(item.identifier)
                                    .font(.caption)
                                Spacer()
                                Text(String(format: "%.2f", item.confidence))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("sidebar.ai.keywords.list")
                }
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
            ? "Recompute keywords for the displayed frame"
            : "Compute keywords for the displayed frame"
        Button(action: recompute) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(displayedStem == nil)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("sidebar.ai.keywords.button")
    }

    private func recompute() {
        guard let stem = displayedStem else { return }
        state.kickOffAIKeywordsCompute(for: stem, force: true)
    }
}
