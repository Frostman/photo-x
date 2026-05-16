import SwiftUI

struct DecisionsPanelView: View {
    let xmp: XMPSidecar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ratingRow
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
            if xmp.isReject {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                    Text("Rejected")
                }
                .font(.caption)
                .foregroundStyle(.red)
            } else {
                StarsView(count: xmp.starCount ?? 0)
            }
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
