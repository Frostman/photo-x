import SwiftUI

/// Slim footer above the filmstrip. Left side shows count breakdown for the
/// current shoot; right side has hide-by-category toggles. Same height as the
/// compact unified titlebar (~30 pt).
struct StatusBarView: View {
    @Bindable var state: ViewerState
    @State private var showIndexingDetails = false

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 12) {
            stats
            Spacer()
            indexingChip
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

    /// Indexer status: hidden when there's no shoot, circular spinner +
    /// percent during indexing, "Re-index" button once everything is in
    /// memory. Sits between the stats and the sort menu so the user can
    /// see exactly when navigation will be cache-only.
    @ViewBuilder
    private var indexingChip: some View {
        switch state.indexingStatus {
        case .idle:
            EmptyView()
        case .indexing(let pct):
            // Click to reveal per-pipeline breakdown. `.plain` button style
            // preserves the chip's visual look (no border/highlight) while
            // making the whole thing a tappable region.
            Button {
                showIndexingDetails.toggle()
            } label: {
                HStack(spacing: 4) {
                    ProgressView(value: pct)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text("Indexing \(Int(pct * 100))%")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Click for per-pipeline breakdown")
            .popover(isPresented: $showIndexingDetails, arrowEdge: .bottom) {
                IndexingProgressPopover(progress: state.indexingProgress)
                    .padding(14)
            }
        case .done, .cancelled:
            Button {
                state.reIndex()
            } label: {
                Label("Re-index", systemImage: "arrow.clockwise")
                    .font(.caption.bold())
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("Re-read EXIF, AF data, XMP sidecars and thumbnails from disk")
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
        // shootStats is O(N over the shoot); call it ONCE and derive
        // shownCount from the same tuple instead of `state.shownCount`
        // (which walks the shoot a second time).
        let s = state.shootStats
        var shown = 0
        for (stars, count) in s.stars where state.showStars.contains(stars) {
            shown += count
        }
        if state.showRejected { shown += s.rejected }
        if state.showUnrated  { shown += s.unrated }
        return HStack(spacing: 6) {
            statChip(label: "rated",    count: s.rated,    color: .yellow)
            Text("·").foregroundStyle(.secondary)
            statChip(label: "rejected", count: s.rejected, color: .red)
            Text("·").foregroundStyle(.secondary)
            statChip(label: "unrated",  count: s.unrated,  color: .secondary)
            if state.filmstripVisible {
                Text("·").foregroundStyle(.secondary)
                Text("\(shown) shown")
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
            // Per-star filter row. Each toggle shows a star icon + the rating
            // number; pressed/highlighted = that star count is visible in the
            // filmstrip. Replaces the previous single "Rated" toggle so the
            // user can cull at 5★, isolate everything below 3★ for review,
            // etc., without leaving the status bar.
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { stars in
                    Toggle(isOn: starBinding(for: stars)) {
                        starLabel(for: stars)
                    }
                    .help("Show / hide \(stars)-star frames")
                }
            }

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

    /// Binding that maps `Set<Int>` membership for a given star count to a Bool
    /// suitable for SwiftUI's Toggle.
    private func starBinding(for stars: Int) -> Binding<Bool> {
        Binding(
            get: { state.showStars.contains(stars) },
            set: { on in
                if on { state.showStars.insert(stars) }
                else  { state.showStars.remove(stars) }
            }
        )
    }

    @ViewBuilder
    private func starLabel(for stars: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: "star.fill")
            Text("\(stars)")
                .font(.caption2.monospacedDigit().bold())
        }
    }
}

/// Click-through breakdown of indexing progress, one row per pipeline.
/// Tracks `state.indexingProgress` live so the bars climb while the
/// popover stays open. Compact (~280 pt wide) — the user just needs to
/// see which pipeline is the bottleneck, not interact with anything.
private struct IndexingProgressPopover: View {
    let progress: ViewerState.IndexingProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Indexing progress")
                .font(.subheadline.bold())
            row("EXIF · AF · sequence",
                value: progress.exif,
                icon: "doc.text.magnifyingglass")
            row("XMP sidecars",
                value: progress.xmp,
                icon: "tag")
            row("Thumbnails",
                value: progress.thumb,
                icon: "photo.on.rectangle.angled")
        }
        .frame(minWidth: 260)
    }

    private func row(_ label: String, value: Double, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
            Spacer()
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .frame(width: 80)
            Text("\(Int(value * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
