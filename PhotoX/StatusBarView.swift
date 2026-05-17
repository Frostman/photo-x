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
            sortMenu
            Divider().frame(height: 18)
            toggles
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortMode.allCases) { mode in
                Button {
                    state.setSortMode(mode)
                } label: {
                    Label(label(for: mode), systemImage: mode.systemImage)
                }
            }
        } label: {
            Label(state.sortMode.displayName, systemImage: state.sortMode.systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort order for the filmstrip and ←/→ navigation")
    }

    private func label(for mode: SortMode) -> String {
        switch mode {
        case .name:             return "Name"
        case .scoreAscending:   return "Score (low → high)"
        case .scoreDescending:  return "Score (high → low)"
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
            if state.filmstripVisible {
                Text("·").foregroundStyle(.secondary)
                Text("\(state.shownCount) shown")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
            Toggle(isOn: $state.showRated) {
                Image(systemName: "star.fill")
            }
            .help("Show / hide rated frames")

            Toggle(isOn: $state.showRejected) {
                Image(systemName: "xmark.circle.fill")
            }
            .help("Show / hide rejected frames")

            Toggle(isOn: $state.showUnrated) {
                Image(systemName: "circle")
            }
            .help("Show / hide unrated frames")
        }
        .toggleStyle(.button)
        .controlSize(.small)
    }
}
