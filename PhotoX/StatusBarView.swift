import SwiftUI

/// Slim footer above the filmstrip. Left side shows count breakdown for the
/// current shoot; right side has hide-by-category toggles. Same height as the
/// compact unified titlebar (~30 pt).
struct StatusBarView: View {
    @Bindable var state: ViewerState

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 12) {
            stats
            Spacer()
            toggles
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    private var stats: some View {
        let s = state.shootStats
        return HStack(spacing: 6) {
            statChip(label: "rated",    count: s.rated,    color: .yellow)
            Text("·").foregroundStyle(.secondary)
            statChip(label: "rejected", count: s.rejected, color: .red)
            Text("·").foregroundStyle(.secondary)
            statChip(label: "unrated",  count: s.unrated,  color: .secondary)
            Text("·").foregroundStyle(.secondary)
            Text("\(s.total) total")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func statChip(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var toggles: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $state.hideRated) {
                Label("Rated", systemImage: "star.slash")
            }
            .help("Hide rated frames from filmstrip and navigation")

            Toggle(isOn: $state.hideRejected) {
                Label("Rejected", systemImage: "xmark.circle")
            }
            .help("Hide rejected frames")

            Toggle(isOn: $state.hideUnrated) {
                Label("Unrated", systemImage: "circle.dashed")
            }
            .help("Hide unrated frames")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}
