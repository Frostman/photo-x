import SwiftUI

struct DecisionsPanelView: View {
    let xmp: XMPSidecar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ratingRow
            labelRow
            if xmp.isReject { rejectedRow }
        }
    }

    @ViewBuilder
    private var ratingRow: some View {
        HStack(spacing: 6) {
            Text("Rating")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            StarsView(count: xmp.starCount ?? 0)
        }
    }

    @ViewBuilder
    private var labelRow: some View {
        if let label = xmp.label, !label.isEmpty {
            HStack(spacing: 6) {
                Text("Label")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                LabelChip(label: label)
            }
        }
    }

    @ViewBuilder
    private var rejectedRow: some View {
        HStack(spacing: 6) {
            Text("Status")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Label("Rejected", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
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
                    .foregroundStyle(i < count ? Color.yellow : Color.secondary.opacity(0.5))
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
