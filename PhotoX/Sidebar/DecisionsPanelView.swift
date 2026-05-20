import SwiftUI

struct DecisionsPanelView: View {
    @Bindable var state: ViewerState

    // Read the DISPLAYED XMP (= what's on the canvas) so the sidebar
    // never shows the not-yet-visible navigation-intent pair's rating.
    // Combined with the `.disabled(state.isLoadingDisplayedPair)` on
    // `body`, this means during a nav lag the sidebar is greyed out
    // AND reads the just-visible pair's decisions.
    private var xmp: XMPSidecar { state.displayedXMP }

    var body: some View {
        // Disable all rating/reject/label inputs while the canvas is
        // showing an older texture than the user's navigation intent
        // — matches the `guard !isLoadingDisplayedPair` on the
        // ViewerState mutators, and visually signals to the user why
        // a click might be a no-op.
        VStack(alignment: .leading, spacing: 6) {
            ratingRow
            rejectRow
            labelRow
        }
        .disabled(state.isLoadingDisplayedPair)
        .opacity(state.isLoadingDisplayedPair ? 0.45 : 1.0)
    }

    @ViewBuilder
    private var ratingRow: some View {
        HStack(spacing: 6) {
            Text("Rating")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        state.toggleRating(value, source: .sidebar)
                    } label: {
                        Image(systemName: value <= (xmp.starCount ?? 0) ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(value <= (xmp.starCount ?? 0)
                                             ? Color.yellow
                                             : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help("Set rating to \(value)")
                }
            }
        }
    }

    @ViewBuilder
    private var rejectRow: some View {
        HStack(spacing: 6) {
            Text("Status")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Button {
                state.toggleReject(source: .sidebar)
            } label: {
                Label(xmp.isReject ? "Rejected" : "Reject",
                      systemImage: xmp.isReject ? "xmark.circle.fill" : "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(xmp.isReject ? Color.red : Color.secondary.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        // Color.primary adapts to scheme: black @ 6% reads on
                        // light backgrounds, white @ 6% reads on dark.
                        // (Color.white was invisible against a light sidebar.)
                        Capsule().fill(xmp.isReject ? Color.red.opacity(0.18) : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle reject (xmp:Rating = -1)")
        }
    }

    @ViewBuilder
    private var labelRow: some View {
        HStack(spacing: 6) {
            Text("Label")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(DecisionsPanelView.labelOrder, id: \.self) { name in
                    Button {
                        state.toggleLabel(name, source: .sidebar)
                    } label: {
                        Circle()
                            .fill(LabelChip.color(for: name))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .stroke(xmp.label == name ? Color.white : Color.white.opacity(0.12),
                                            lineWidth: xmp.label == name ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Set color label to \(name)")
                }
            }
        }
    }

    static let labelOrder = ["Red", "Yellow", "Green", "Blue", "Purple"]
}

struct StarsView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5) { i in
                Image(systemName: i < count ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(i < count ? Color.yellow : Color.secondary.opacity(0.35))
            }
        }
    }
}

struct LabelChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Self.color(for: label), in: Capsule())
    }

    static func color(for label: String) -> Color {
        switch label.lowercased() {
        case "red":    return .red
        case "yellow": return .yellow.opacity(0.85)
        case "green":  return .green
        case "blue":   return .blue
        case "purple": return .purple
        default:       return .gray
        }
    }
}
