import SwiftUI

struct FilmstripView: View {
    @Bindable var state: ViewerState

    @AppStorage(SettingsKey.collapseBursts, store: AppDefaults.shared)
    private var collapseBursts = SettingsKey.Defaults.collapseBursts

    static let height: CGFloat = 108

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    if state.shoot != nil {
                        // Two parallel arrays: `visible` for display + bracket
                        // adjacency, `visibleSortedIndices` to map each thumb
                        // back to its position in state.sortedEntries (which is
                        // what state.currentIndex and navigate(to:) use).
                        let allVisible = state.sortedEntries.enumerated()
                            .filter { state.isVisible($1) }
                        let useBrackets = state.sortMode == .name
                        // Hoist the burst id / size tables ONCE per render.
                        // Both are O(N over the shoot); calling the per-cell
                        // `state.burstSegment(at:visible:)` repeatedly would
                        // make filmstrip rendering O(visible × N) and beach
                        // the main thread on 3 k+ entry shoots.
                        let burstIDs   = useBrackets ? state.burstIDByStem   : [:]
                        let burstSizes = useBrackets ? state.burstSizesByID  : [:]
                        // Burst id of the focused entry — its burst auto-expands
                        // in collapsed mode so the user can step through it.
                        let currentBurstID: Int? = state.displayedEntry
                            .flatMap { burstIDs[$0.stem] }
                        // Collapse pass: keep singletons and the expanded
                        // burst; for every other burst, keep only its first
                        // visible frame. Only kicks in for .name sort, where
                        // burst frames are contiguous.
                        // Collapse is force-off while indexing is in flight —
                        // the burst id table is still being built up batch-
                        // by-batch and collapsing would hide siblings that
                        // haven't been detected yet. `state.collapseBurstsActive`
                        // bakes the same gate in for nav handlers.
                        let collapseActive = collapseBursts && !state.isIndexingActive
                        let enumeratedVisible: [(offset: Int, element: PhotoEntry)] = {
                            guard collapseActive, useBrackets else { return allVisible }
                            var seen: Set<Int> = []
                            return allVisible.filter { _, entry in
                                guard let id = burstIDs[entry.stem],
                                      (burstSizes[id] ?? 0) >= 2
                                else { return true }                  // singleton
                                if id == currentBurstID { return true } // expanded
                                return seen.insert(id).inserted        // 1st of burst
                            }
                        }()
                        let visible = enumeratedVisible.map(\.element)
                        let visibleSortedIndices = enumeratedVisible.map(\.offset)
                        // Precompute first/last visible index per burst id —
                        // O(visible) once per render. Per-cell bracket lookup
                        // is then O(1). Replaces the previous static helper
                        // call that walked the visible array left + right per
                        // cell (worst case O(visible²) per render — the prime
                        // filmstrip-perf regression since v0.182.0).
                        let (firstByBurst, lastByBurst): ([Int: Int], [Int: Int]) = {
                            guard useBrackets else { return ([:], [:]) }
                            var first: [Int: Int] = [:]
                            var last:  [Int: Int] = [:]
                            for (vIdx, entry) in visible.enumerated() {
                                guard let id = burstIDs[entry.stem],
                                      (burstSizes[id] ?? 0) >= 2 else { continue }
                                if first[id] == nil { first[id] = vIdx }
                                last[id] = vIdx
                            }
                            return (first, last)
                        }()
                        let _ = {
                            PerfTracker.mark("FilmstripView.body: visible=\(visible.count), bursts=\(firstByBurst.count), brackets=\(useBrackets)")
                        }()
                        ForEach(visible.indices, id: \.self) { vIdx in
                            let entry = visible[vIdx]
                            let sortedIdx = visibleSortedIndices[vIdx]
                            // Nx badge only on collapsed-representative thumbs:
                            // burst size ≥ 2 AND this burst isn't currently
                            // expanded AND collapse mode is on.
                            let collapsedBurstSize: Int? = {
                                guard collapseActive, useBrackets,
                                      let id = burstIDs[entry.stem],
                                      id != currentBurstID,
                                      let size = burstSizes[id], size >= 2
                                else { return nil }
                                return size
                            }()
                            let segment: ViewerState.BurstSegment = {
                                guard useBrackets,
                                      let myID = burstIDs[entry.stem],
                                      let first = firstByBurst[myID],
                                      let last  = lastByBurst[myID]
                                else { return .none }
                                if first == last { return .solo }
                                switch vIdx {
                                case first: return .start
                                case last:  return .end
                                default:    return .middle
                                }
                            }()
                            FilmstripThumbnailView(
                                entry: entry,
                                isSelected: sortedIdx == state.displayedIndex,
                                thumbnail: state.thumbnails[entry.stem],
                                xmp: state.entryXMPs[entry.stem] ?? .empty,
                                burstSegment: segment,
                                collapsedBurstSize: collapsedBurstSize,
                                onTap: { state.navigate(to: sortedIdx) },
                                onAppear: { state.prioritizeBatch(forStem: entry.stem) }
                            )
                            .id(sortedIdx)
                            .accessibilityIdentifier("filmstrip.thumb.\(sortedIdx)")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: Self.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
            .accessibilityIdentifier("filmstrip.container")
            .onAppear {
                proxy.scrollTo(state.displayedIndex, anchor: .center)
            }
            .onChange(of: state.displayedIndex) { _, newIdx in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
    }
}

struct FilmstripThumbnailView: View {
    let entry: PhotoEntry
    let isSelected: Bool
    let thumbnail: CGImage?
    let xmp: XMPSidecar
    let burstSegment: ViewerState.BurstSegment
    /// When non-nil, this thumb is the representative of a collapsed
    /// burst of this size — renders an "Nx" badge in the top-left.
    let collapsedBurstSize: Int?
    let onTap: () -> Void
    let onAppear: () -> Void

    private static let thumbHeight: CGFloat = 84
    private static let thumbAspectFallbackWidth: CGFloat = 126 // 3:2

    var body: some View {
        thumbnailImage
            .overlay(alignment: .topTrailing) { namePill.padding(3) }
            .overlay(alignment: .topLeading)  { burstSizePill.padding(3) }
            .overlay(alignment: .bottomTrailing) { scorePill.padding(3) }
            .overlay(
                // Accent (system selection blue) for the selected thumbnail —
                // Color.primary blended into thumbnail content was almost
                // invisible on light theme. Idle thumbnails keep primary @ 12%
                // for a subtle grid line that still adapts to scheme.
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.green : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 3 : 1)
            )
            .overlay(alignment: .top) { burstOverlay }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onAppear(perform: onAppear)
            .help(entry.stem)
    }

    @ViewBuilder
    private var burstSizePill: some View {
        if let n = collapsedBurstSize {
            Text("\(n)×")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.85), in: Capsule())
        }
    }

    /// One slice of the top-edge bracket that joins a horizontal run of
    /// burst-shot frames in the filmstrip. Drawn ABOVE the thumbnail (in
    /// the gap between the filmstrip's top separator and the image) so it
    /// doesn't compete with image content. .start = right-half bar + a
    /// downward cap from the bar's left edge; .end mirrors that; .middle
    /// is a full-width bar; .none renders nothing. Bar widths line up so
    /// adjacent thumbnails' segments read as one continuous ⌐——¬ bracket.
    ///
    /// Layout math: 84-pt thumb sits in a 108-pt filmstrip with 6-pt
    /// vertical padding, leaving 6 pt above the image. We use 4 pt for
    /// the bar + 2 pt for the cap drop = 6 pt total, then offset the
    /// whole overlay up by that amount so the cap's bottom touches the
    /// thumbnail's top edge. Filmstrip height stays unchanged.
    @ViewBuilder
    private var burstOverlay: some View {
        let barHeight: CGFloat = 4
        let capDrop: CGFloat = 2
        let totalHeight = barHeight + capDrop
        // Half of the LazyHStack's 6-pt inter-thumb spacing. Each segment
        // bleeds this much past its participating edge so adjacent
        // thumbnails' bars meet at the midpoint of the gap.
        let bleed: CGFloat = 3
        switch burstSegment {
        case .none:
            EmptyView()
        case .start:
            HStack(spacing: 0) {
                Spacer().frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight)
                        .padding(.trailing, -bleed)   // bridge gap to next thumb
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: barHeight, height: capDrop)
                }
            }
            .offset(y: -totalHeight)
        case .middle:
            Rectangle()
                .fill(Color.accentColor)
                .frame(maxWidth: .infinity)
                .frame(height: barHeight)
                .padding(.horizontal, -bleed)         // bridge gaps on both sides
                // Align the middle bar with start/end bars (which sit above
                // their caps), not flush against the thumbnail.
                .offset(y: -totalHeight)
        case .end:
            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight)
                        .padding(.leading, -bleed)    // bridge gap to previous thumb
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: barHeight, height: capDrop)
                }
                Spacer().frame(maxWidth: .infinity)
            }
            .offset(y: -totalHeight)
        case .solo:
            // Lone visible burst member: a centered short bar with
            // caps on both sides so the user can still tell this
            // frame belongs to a burst even though its siblings
            // are filtered out.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: barHeight * 4, height: barHeight)
                    Spacer()
                }
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: barHeight, height: capDrop)
                    Spacer().frame(width: barHeight * 2)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: barHeight, height: capDrop)
                    Spacer()
                }
            }
            .offset(y: -totalHeight)
        }
    }

    @ViewBuilder
    private var namePill: some View {
        Text(entry.stem)
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.85))
            // Single line always; on narrow (portrait) thumbs truncate
            // the FRONT so the unique numeric tail stays visible —
            // "DSC04207" → "…04207". The constant "DSC" prefix is
            // expendable; the digits are how the user identifies the
            // frame.
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.black.opacity(0.7), in: Capsule())
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: Self.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.18))
                .frame(width: Self.thumbAspectFallbackWidth, height: Self.thumbHeight)
                .overlay(
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.4))
                )
        }
    }

    @ViewBuilder
    private var scorePill: some View {
        HStack(spacing: 3) {
            if let label = xmp.label, !label.isEmpty {
                Circle()
                    .fill(color(for: label))
                    .frame(width: 6, height: 6)
            }
            if xmp.isReject {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if let stars = xmp.starCount {
                Text("★\(stars)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(scorePillVisible ? AnyShapeStyle(Color.black.opacity(0.7)) : AnyShapeStyle(Color.clear),
                    in: Capsule())
    }

    private var scorePillVisible: Bool {
        xmp.isReject || xmp.starCount != nil || (xmp.label?.isEmpty == false)
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
