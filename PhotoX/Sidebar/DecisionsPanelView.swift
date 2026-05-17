import SwiftUI

struct DecisionsPanelView: View {
    @Bindable var state: ViewerState

    private var xmp: XMPSidecar { state.currentXMP }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ratingRow
            rejectRow
            labelRow
        }
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
                        state.toggleRating(value)
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
                state.toggleReject()
            } label: {
                Label(xmp.isReject ? "Rejected" : "Reject",
                      systemImage: xmp.isReject ? "xmark.circle.fill" : "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(xmp.isReject ? Color.red : Color.secondary.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(xmp.isReject ? Color.red.opacity(0.18) : Color.white.opacity(0.06))
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
            if let label = xmp.label, !label.isEmpty {
                LabelChip(label: label)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.4))
            }
        }
    }
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
            .background(color(for: label), in: Capsule())
    }

    private func color(for label: String) -> Color {
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
