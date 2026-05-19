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
    /// "Indexing N%" during indexing, green-check "Indexed" once finished.
    /// Either state opens the same popover; the popover hosts the
    /// per-pipeline breakdown plus the Re-index button + "Xm ago" label.
    /// Button + popover identity is preserved across status transitions
    /// so the popover stays open through Re-index / Done flips.
    @ViewBuilder
    private var indexingChip: some View {
        if case .idle = state.indexingStatus {
            EmptyView()
        } else {
            Button {
                showIndexingDetails.toggle()
            } label: {
                indexingChipContent
            }
            .buttonStyle(.plain)
            .help("Click for indexing details")
            .popover(isPresented: $showIndexingDetails, arrowEdge: .bottom) {
                IndexingProgressPopover(
                    progress: state.indexingProgress,
                    timings: state.indexingTimings,
                    completedAt: state.indexingCompletedAt,
                    onReindex: { state.reIndex() }
                )
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var indexingChipContent: some View {
        switch state.indexingStatus {
        case .idle:
            EmptyView()
        case .indexing(let pct):
            HStack(spacing: 4) {
                ProgressView(value: pct)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text("Indexing \(Int(pct * 100))%")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
            }
        case .done, .cancelled:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Indexed")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
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
/// Tracks `state.indexingProgress` + `state.indexingTimings` live so the
/// bars and ETAs update while the popover stays open. Once a pipeline
/// hits 100 %, its ETA is replaced by a static "took Ns" reading.
///
/// When `completedAt != nil` the popover also shows an "Indexed Xm ago"
/// header (TimelineView-driven so it ticks) and a Re-index button at
/// the bottom. The host (StatusBarView) keeps these on the same
/// popover identity across status transitions so it stays open through
/// a Re-index click.
private struct IndexingProgressPopover: View {
    let progress: ViewerState.IndexingProgress
    let timings: ViewerState.PipelineTimings
    let completedAt: Date?
    let onReindex: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Indexing progress")
                    .font(.subheadline.bold())
                Spacer()
                if let completedAt {
                    // Tick the "X ago" once a minute. agoString is
                    // minute-precision so faster updates would be wasted.
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        Text("Indexed \(agoString(from: completedAt, now: ctx.date))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            row("Basic EXIF + thumbs",
                value: progress.basicExifAndThumbs,
                timing: timings.basicExifAndThumbs,
                icon: "photo.on.rectangle.angled")
            row("Advanced EXIF: AF/seq",
                value: progress.advancedExif,
                timing: timings.advancedExif,
                icon: "doc.text.magnifyingglass")
            row("XMP sidecars",
                value: progress.xmpSidecars,
                timing: timings.xmpSidecars,
                icon: "tag")
            if completedAt != nil {
                Divider().padding(.vertical, 2)
                HStack {
                    Spacer()
                    Button {
                        onReindex()
                    } label: {
                        Label("Re-index", systemImage: "arrow.clockwise")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Re-read EXIF, AF data, XMP sidecars and thumbnails from disk")
                }
            }
        }
        .frame(minWidth: 360)
    }

    private func row(_ label: String,
                     value: Double,
                     timing: ViewerState.PipelineTiming,
                     icon: String) -> some View {
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
            Text(timingLabel(value: value, timing: timing))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                // Leading-align in a fixed-width slot so digits don't
                // shift left/right as the value changes (only the right
                // edge grows). 84 pt fits "took 1h 10m" / "ETA 99m".
                .frame(width: 84, alignment: .leading)
        }
    }

    /// "took 18s" once the pipeline has marked finishedAt; "ETA Ns" while
    /// in flight (after at least 500 ms of signal); empty string otherwise
    /// (just spawned, or zero-batch pipeline).
    private func timingLabel(value: Double,
                             timing: ViewerState.PipelineTiming) -> String {
        if let d = timing.duration {
            return "took \(formattedDuration(d))"
        }
        let now = CFAbsoluteTimeGetCurrent()
        if let eta = timing.eta(progress: value, now: now) {
            return "ETA \(formattedDuration(eta))"
        }
        return ""
    }
}
