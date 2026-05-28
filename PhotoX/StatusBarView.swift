import SwiftUI

/// Slim footer above the filmstrip. Left side shows count breakdown for the
/// current shoot; right side has hide-by-category toggles. Same height as the
/// compact unified titlebar (~30 pt).
struct StatusBarView: View {
    @Bindable var state: ViewerState
    @State private var showIndexingDetails = false
    @AppStorage(SettingsKey.collapseBursts, store: AppDefaults.shared)
    private var collapseBursts = SettingsKey.Defaults.collapseBursts

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 12) {
            stats
            Spacer()
            indexingChip
            sortMenu
            collapseBurstsButton
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
            // E2E hook: status visible to XCUITest as the
            // button's accessibility identifier. `indexing` /
            // `done` change as the pipelines progress; tests
            // wait for `done` before asserting cache behaviour.
            .accessibilityIdentifier({
                switch state.indexingStatus {
                case .idle:       return "indexer.statusChip.idle"
                case .indexing:   return "indexer.statusChip.indexing"
                case .done:       return "indexer.statusChip.done"
                case .cancelled:  return "indexer.statusChip.cancelled"
                }
            }())
            .popover(isPresented: $showIndexingDetails, arrowEdge: .bottom) {
                IndexingProgressPopover(
                    progress: state.indexingProgress,
                    timings: state.indexingTimings,
                    completedAt: state.indexingCompletedAt,
                    shootFolder: state.shoot?.folderURL,
                    cacheHits: state.indexerCacheHitsThisOpen,
                    cacheMisses: state.indexerCacheMissesThisOpen,
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

    /// Filmstrip-only display toggle. Hides all-but-the-first frame
    /// of each burst; the burst the user is currently inside auto-
    /// expands. Doesn't affect navigation — arrows still walk every
    /// frame. Gated to `.name` sort because burst frames are only
    /// contiguous there; in other sorts we render an invisible
    /// placeholder so the status-bar layout doesn't shift when the
    /// user changes sort mode.
    @ViewBuilder
    private var collapseBurstsButton: some View {
        // sortMode gate: bursts are only contiguous in .name sort, so
        // the button is hidden in score sort to avoid a misleading
        // toggle. indexing gate: the burst table is built up batch-
        // by-batch; let the user only enable collapsing once it's
        // complete.
        let availableForSort = state.sortMode == .name
        let availableForIndex = !state.isIndexingActive
        let available = availableForSort && availableForIndex
        let effective = collapseBursts && availableForIndex
        Button {
            collapseBursts.toggle()
        } label: {
            Image(systemName: effective
                ? "rectangle.stack.fill"
                : "rectangle.stack")
                .foregroundStyle(effective ? Color.accentColor : .secondary)
                .font(.callout)
        }
        .buttonStyle(.plain)
        .help(availableForIndex
              ? "Collapse bursts in filmstrip (\(effective ? "on" : "off")) — the burst you're inside stays expanded"
              : "Collapse bursts disabled while indexing — burst membership is still being detected")
        .accessibilityIdentifier("statusbar.collapseBursts")
        .opacity(availableForSort ? 1 : 0)
        .disabled(!available)
        .allowsHitTesting(available)
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
        let _ = { PerfTracker.mark("StatusBarView.stats rendering") }()
        // shootStats is O(N over the shoot); call it ONCE and derive
        // shownCount from the same tuple instead of `state.shownCount`
        // (which walks the shoot a second time).
        let s = state.shootStats
        let _ = { PerfTracker.mark("StatusBarView.stats: shootStats done (rated=\(s.rated) rejected=\(s.rejected) unrated=\(s.unrated))") }()
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
    /// nil when no shoot is open. Drives the cache-size row +
    /// the "delete this shoot" menu item.
    let shootFolder: URL?
    /// How many cache hits / misses the current indexer run
    /// observed. Surfaced in the Cache section + exposed via
    /// accessibility identifiers so RelaunchTests can verify
    /// the indexer cache is actually being read on a warm reopen.
    let cacheHits: Int
    let cacheMisses: Int
    let onReindex: () -> Void

    @State private var thisShootSize: Int64 = 0
    @State private var totalCacheSize: Int64 = 0
    @State private var showDeleteChoices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Indexing progress")
                    .font(.subheadline.bold())
                Spacer()
                if let completedAt {
                    // Wall time = max(per-pipeline duration) because
                    // the three pipelines run in parallel. Computed
                    // outside the TimelineView since duration is
                    // fixed once indexing finishes; agoString is the
                    // only piece that needs the per-minute tick.
                    let totalDuration: TimeInterval? = {
                        let ds = [timings.basicExifAndThumbs.duration,
                                  timings.advancedExif.duration,
                                  timings.xmpSidecars.duration]
                            .compactMap { $0 }
                        return ds.isEmpty ? nil : ds.max()
                    }()
                    let took: String? = totalDuration.map {
                        "took \(formattedDuration($0))"
                    }
                    // Tick the "X ago" once a minute. agoString is
                    // minute-precision so faster updates would be wasted.
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        let ago = "indexed \(agoString(from: completedAt, now: ctx.date))"
                        Text(took.map { "\($0) · \(ago)" } ?? ago)
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
            Divider().padding(.vertical, 2)
            cacheSection
            if completedAt != nil {
                HStack(alignment: .center) {
                    deleteCacheButton
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
            } else {
                HStack { deleteCacheButton; Spacer() }
            }
        }
        .frame(minWidth: 360)
        .task { refreshCacheSizes() }
    }

    // MARK: Cache UI

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text("Cache")
                    .font(.caption.bold())
                Spacer()
            }
            if shootFolder != nil {
                HStack(spacing: 8) {
                    Text("  This shoot:")
                    Text(Self.formatBytes(thisShootSize))
                        .font(.caption.monospacedDigit())
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("  Total:")
                Text("\(Self.formatBytes(totalCacheSize)) / \(Self.formatBytes(IndexerCache.policy.maxTotalBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(totalCacheSize > IndexerCache.policy.maxTotalBytes
                                     ? .red : .secondary)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("  This open:")
                Text("\(cacheHits) hits")
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("indexer.cache.hits")
                Text("·")
                Text("\(cacheMisses) misses")
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("indexer.cache.misses")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var deleteCacheButton: some View {
        // Plain Button (matches Re-index style) → user picks scope
        // via a confirmationDialog. Earlier Menu variants drew an
        // auto-focused highlight on popover open because Menu is
        // the first focusable element.
        Button {
            showDeleteChoices = true
        } label: {
            Label("Delete cache", systemImage: "trash")
                .font(.caption.bold())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Remove cached indexer data. Next open re-reads from source.")
        .confirmationDialog("Delete indexer cache",
                            isPresented: $showDeleteChoices,
                            titleVisibility: .visible) {
            if let shootFolder {
                Button("Delete this shoot's cache") {
                    IndexerCache.deleteCache(for: shootFolder)
                    refreshCacheSizes()
                }
            }
            Button("Delete all caches", role: .destructive) {
                IndexerCache.deleteAllCaches()
                refreshCacheSizes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached indexer data only — the photos themselves are unaffected. The next open will re-read EXIF / AF / thumbnails from the source files.")
        }
    }

    private func refreshCacheSizes() {
        thisShootSize = shootFolder.map { IndexerCache.cacheSize(for: $0) } ?? 0
        totalCacheSize = IndexerCache.totalSize()
    }

    private static func formatBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: n)
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
