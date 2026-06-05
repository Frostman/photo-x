import SwiftUI

/// One annotation in the annotated-help overlay: brackets the
/// anchored region, draws an arrow to a labelled callout, and
/// surfaces relevant keyboard shortcuts as small badges. The
/// catalog below is authored by hand — author-specified
/// `labelEdge` per entry avoids any collision-avoidance
/// algorithm.
struct HelpAnnotation: Hashable, Identifiable, Sendable {
    let id: HelpAnchorID
    let title: String
    let message: String
    let shortcuts: [String]
    /// Which side of the anchor the callout sits on.
    let labelEdge: AnchorEdge

    /// Where the callout sits relative to the bracket.
    /// `.top` / `.bottom` / `.leading` / `.trailing` put the
    /// callout OUTSIDE the bracket on that edge. `.insideTop`
    /// / `.insideBottom` put it INSIDE the bracket along that
    /// edge — used for very large anchors like the canvas
    /// where placing the callout outside would shove it over
    /// a sibling UI region (sidebar / filmstrip) and hide
    /// the very thing we're trying to explain.
    enum AnchorEdge: Hashable, Sendable {
        case top, bottom, leading, trailing
        case insideTop, insideBottom, insideCenter

        /// True when the callout sits within the bracket
        /// rather than outside it. Used by `AnnotationView`
        /// to skip arrow drawing — the bracket framing the
        /// callout is self-evident.
        var isInside: Bool {
            switch self {
            case .insideTop, .insideBottom, .insideCenter: return true
            case .top, .bottom, .leading, .trailing: return false
            }
        }
    }
}

private let helpAnnotations: [HelpAnnotation] = [
    // Canvas callout still goes BELOW the canvas — placing it
    // above would push the long shortcut list under the
    // toolbar / off the top of the window.
    .init(id: .canvas, title: "Image canvas",
          message: "The displayed frame. Pinch / ⌘+scroll to zoom; drag to pan. Toggle overlays for the AF box, clipping zebra (magenta = blown highlights, blue = crushed shadows), and focus peaking (orange tint over in-focus edges).",
          shortcuts: ["⌘0 fit", "double-click 100% (native)",
                      "X swap to RAW", "⇧X cycle decoder",
                      "A AF overlay", "C clipping", "F focus peaking"],
          // Centred INSIDE the canvas — keeps the callout off
          // both the filmstrip (which has its own .top callout
          // landing just above its bracket = canvas bottom)
          // and the toolbar.
          labelEdge: .insideCenter),

    .init(id: .filmstrip, title: "Filmstrip",
          message: "All frames in the shoot. Click a thumb to jump. A thin colored bracket drawn on top of consecutive thumbnails marks a burst (frames the camera shot back-to-back in continuous mode). The corner badge on each thumb shows its rating + color label.",
          shortcuts: ["← / →", "⌥ ← / → skip 10", "⌘ ← / → jump burst",
                      "[ / ] previous / next unrated", "J jump to entry",
                      "Home / End (or fn+← / fn+→) first / last"],
          labelEdge: .top),

    // No umbrella `.sidebar` annotation — the four sub-panels
    // below cover everything visible inside the sidebar.
    .init(id: .decisions, title: "Decisions",
          message: "Rate, label, and reject the displayed frame. All changes write to a Lightroom- and Photomator-compatible XMP sidecar next to the original.",
          shortcuts: ["1–5 stars", "0 clear", "R reject",
                      "⇧1–5 color label",
                      "G burst-reject siblings",
                      "⌘Z undo",
                      "⌘⇧Z redo"],
          labelEdge: .leading),

    .init(id: .histogram, title: "Histogram",
          message: "Live RGB distribution of the displayed image.",
          shortcuts: [],
          labelEdge: .leading),

    .init(id: .exif, title: "EXIF",
          message: "Camera, lens, shutter, aperture, ISO, focal length, and capture date — parsed in-process from the HEIF / JPEG header.",
          shortcuts: [],
          labelEdge: .leading),

    .init(id: .autofocus, title: "Autofocus",
          message: "AF mode, area, tracking, distance, and points used. The Location row indicates whether the file carries a usable focus position. Click the ladybug for raw region coordinates.",
          shortcuts: ["A toggle on-canvas AF box"],
          labelEdge: .leading),

    .init(id: .indexerChip, title: "Indexer",
          message: "Live indexing progress while a shoot loads. Click for per-pipeline ETAs, cache hits / misses, total wall time, and a Re-index button.",
          shortcuts: [],
          labelEdge: .top),

    .init(id: .viewControls, title: "View controls",
          message: "Sort order (filename / rating), collapse bursts (one frame per burst in the filmstrip), and per-rating filters (show/hide stars, reject, unrated). The count chips on the left always reflect the full shoot — filters only affect what's shown.",
          shortcuts: [],
          labelEdge: .top),

    .init(id: .workspaceMode, title: "Workspace",
          message: "Switch between picking a folder (Open), viewing the shoot (View), and configuring the export (Export). Switching is free — your export configuration and any in-progress run are preserved.",
          shortcuts: ["⌘1 Open", "⌘2 View", "⌘3 Export"],
          labelEdge: .bottom),

    // Export-pane callouts. Only published while `mode == .export`,
    // so the View-mode overlay is unaffected. Project + destinations
    // callouts hang in the right-side gutter that the 800pt-capped
    // centred pane opens up on wide windows — keeps them off the
    // pane content where the destination-card / export-all callouts
    // already live.
    .init(id: .exportProject, title: "Project name",
          message: "The subfolder name PhotoX creates under each destination — files land at <destination>/<project name>/. The toggle below makes 'Export all' read each source file once and write it to every destination in parallel, saving I/O on slow source media (SD cards).",
          shortcuts: [],
          labelEdge: .trailing),

    .init(id: .exportDestinations, title: "Destinations",
          message: "Add one or more folders to export to. Each row gets its own run/cancel/remove controls and a 'remove orphans' toggle that deletes files at the destination whose stem isn't in the filtered selection. Drag rows to reorder.",
          shortcuts: [],
          labelEdge: .trailing),

    .init(id: .exportRun, title: "Export all",
          message: "Kicks off the export to every destination at once (Return). Aggregate progress + ETA appear in the footer while running, and on the Export tab in the toolbar so you can switch back to the viewer without losing sight of it.",
          shortcuts: ["↩ run"],
          labelEdge: .top),

    .init(id: .exportDestinationCard, title: "Destination card",
          message: "One card per destination. Per-card controls: click the path to copy it, Run / Cancel for just this destination, star + reject + unrated + file-type filters (further narrow what the global selection sends here), overwrite policy (skip / overwrite / overwrite-if-different), and 'remove orphans' (destructive — deletes files at this destination whose stem isn't in the filtered selection).",
          shortcuts: [],
          labelEdge: .bottom),

    // Open-tab callouts. Only published while the Open tab is
    // active (the OpenStarterView itself only mounts in that
    // mode, so the anchors are naturally bounded).
    .init(id: .openFolderButton, title: "Open Folder",
          message: "Pick a folder of ARW + HIF/JPG pairs (or standalone HIF/JPG files) to load as a shoot. You can also drag a folder onto the window from Finder.",
          shortcuts: ["⌘O"],
          labelEdge: .top),

    .init(id: .openFavorites, title: "Favorites",
          message: "Folders you've starred. Click a row to reopen — PhotoX restores the last photo you were on. Drag the grip to reorder; the × removes from favorites.",
          shortcuts: [],
          labelEdge: .trailing),

    .init(id: .openCards, title: "Cards",
          message: "Auto-detected SD / CFExpress cards with DCIM shoots. Click a row to open the shoot; the eject button unmounts the whole card.",
          shortcuts: [],
          labelEdge: .trailing),

    .init(id: .openRecents, title: "Recent",
          message: "Recently-opened folders. Star a row to pin it to Favorites; × removes it from the recents list. Reopening restores the last photo viewed.",
          shortcuts: [],
          labelEdge: .trailing),
]

/// The annotated help layer. Sits inside `ContentView`'s
/// ZStack on top of the dimmer; reads anchor frames from the
/// `HelpAnchorStore` and draws bracket + arrow + callout
/// triplets for every annotation whose anchor is currently
/// publishing a frame (panels that are off-screen drop out
/// naturally).
///
/// Callout sizes are measured up here (not inside each
/// `AnnotationView`) so a single layout pass can resolve
/// overlaps by shifting callouts along the cross axis of
/// their `labelEdge`. Stacked sidebar callouts (all
/// `.leading`) get pushed vertically so they don't stack on
/// top of each other; status-bar callouts (all `.top`) get
/// pushed horizontally for the same reason.
struct HelpAnnotationOverlay: View {
    let store: HelpAnchorStore
    let onDismiss: () -> Void

    @State private var calloutSizes: [HelpAnchorID: CGSize] = [:]

    var body: some View {
        // GeometryReader gives us the overlay's full bounds,
        // which BracketView uses to clamp the bracket stroke so
        // it doesn't run past the window edge for anchors that
        // sit flush against the sidebar / status bar / filmstrip
        // perimeter.
        GeometryReader { geo in
            let overlayBounds = CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                // Tap-to-dismiss dimmer. Material so the live UI
                // shows through softly instead of being completely
                // blacked out — a new user can see WHAT we're
                // pointing at while reading the callouts.
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                // Cut-outs would be nice (punch holes in the dimmer
                // around each anchor) but require a mask layer.
                // v1 skips that — the brackets read clearly enough
                // on top of a uniform dim.

                let centers = resolvedCalloutCenters(
                    brackets: store.rects, sizes: calloutSizes)

                // Two-pass rendering: every bracket first (bottom
                // layer), every callout card + arrow second (top
                // layer). Splitting the passes guarantees no
                // annotation's bracket ever lands above another
                // annotation's card — bracket-on-card bleed used to
                // happen when a later iteration's bracket composited
                // over an earlier iteration's callout in a single-
                // ForEach setup.
                ForEach(helpAnnotations) { annotation in
                    if let rect = store.rects[annotation.id] {
                        BracketView(rect: rect, bounds: overlayBounds)
                    }
                }

                ForEach(helpAnnotations) { annotation in
                    if let rect = store.rects[annotation.id] {
                        CalloutCardView(
                            rect: rect,
                            annotation: annotation,
                            calloutCenter: centers[annotation.id],
                            reportSize: { size in
                                if calloutSizes[annotation.id] != size {
                                    calloutSizes[annotation.id] = size
                                }
                            }
                        )
                    }
                }

                // Footer hint — bottom-center, easy to spot.
                VStack {
                    Spacer()
                    Text("Press ? again or Esc to dismiss · Help → Keyboard Shortcuts for the full list")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
            // `.contain` keeps every child (brackets, callouts, footer
            // hint) independently accessible to VoiceOver while still
            // creating a single AX element for the ZStack itself —
            // without this, `.accessibilityIdentifier` propagates the
            // identifier to every leaf StaticText, and the XCUITest
            // query `app.otherElements["help.annotationOverlay"]` can't
            // find an `Other`-type element to match. Verified via the
            // failure-ax-tree on a HelpOverlayTests run.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("help.annotationOverlay")
        }
    }

    /// Compute the final centre point for every callout,
    /// resolving overlaps within each `labelEdge` bucket via
    /// a bidirectional 1D constraint solver that also clamps
    /// the leading + trailing items to the canvas bounds.
    /// Net result: no overlaps + every callout fits inside
    /// the canvas (as long as the total required size fits).
    private func resolvedCalloutCenters(
        brackets: [HelpAnchorID: CGRect],
        sizes: [HelpAnchorID: CGSize]
    ) -> [HelpAnchorID: CGPoint] {
        let gap: CGFloat = HelpLayout.calloutGap
        let separation: CGFloat = 8     // padding between adjacent callouts
        let canvasMargin: CGFloat = 8   // padding from canvas edges

        var out: [HelpAnchorID: CGPoint] = [:]
        let byEdge = Dictionary(grouping: helpAnnotations) { $0.labelEdge }

        // Canvas bounds for clamping. If no canvas anchor has
        // reported yet (early frames) we skip clamping; the
        // next render will land it.
        let canvasBounds = brackets[.canvas]?.insetBy(dx: canvasMargin,
                                                       dy: canvasMargin)

        for (edge, anns) in byEdge {
            // Sort by cross-axis position of the bracket so
            // the "first" callout is the one closest to the
            // canvas near edge along that axis.
            let isVertical = (edge == .leading || edge == .trailing)
            let sorted = anns.compactMap { ann -> (HelpAnnotation, CGRect, CGSize)? in
                guard let b = brackets[ann.id],
                      let s = sizes[ann.id], s != .zero else { return nil }
                return (ann, b.insetBy(dx: HelpLayout.bracketInset,
                                       dy: HelpLayout.bracketInset), s)
            }.sorted { a, b in
                isVertical ? a.1.midY < b.1.midY : a.1.midX < b.1.midX
            }

            // Preferred centres before constraints.
            let preferred = sorted.map {
                preferredCenter(bracket: $0.1, size: $0.2, edge: edge, gap: gap)
            }

            // Cross-axis coordinates + sizes (where collisions happen).
            let crossPreferred: [CGFloat] = preferred.map { isVertical ? $0.y : $0.x }
            let crossSizes:     [CGFloat] = sorted.map    { isVertical ? $0.2.height : $0.2.width }
            let low  = canvasBounds.map { isVertical ? $0.minY : $0.minX }
            let high = canvasBounds.map { isVertical ? $0.maxY : $0.maxX }
            let crossResolved = solve1D(preferred: crossPreferred,
                                         sizes: crossSizes,
                                         separation: separation,
                                         low: low, high: high)

            // Re-assemble + clamp the main (non-collision) axis.
            for i in 0..<sorted.count {
                var pt = preferred[i]
                if isVertical { pt.y = crossResolved[i] }
                else          { pt.x = crossResolved[i] }
                if let canvasBounds {
                    pt = clamp(pt, size: sorted[i].2, within: canvasBounds)
                }
                out[sorted[i].0.id] = pt
            }
        }
        return out
    }

    /// 1D constraint solver: place N centres along an axis
    /// such that adjacent items don't overlap (with
    /// `separation` padding) and the first/last stay within
    /// `[low, high]`. Iterates forward + backward up to 8
    /// times to converge. If the items can't possibly fit
    /// (total size + padding > `high - low`), returns
    /// preferred centres unchanged — overlap is inevitable.
    private func solve1D(preferred: [CGFloat],
                         sizes: [CGFloat],
                         separation: CGFloat,
                         low: CGFloat?,
                         high: CGFloat?) -> [CGFloat] {
        let n = preferred.count
        guard n > 0 else { return [] }
        let totalRequired = sizes.reduce(0, +)
                          + CGFloat(max(n - 1, 0)) * separation
        if let low, let high, totalRequired > high - low {
            return preferred  // can't fit — accept overlap
        }
        var pos = preferred
        let maxIter = 8
        for _ in 0..<maxIter {
            var moved = false
            // Forward: push i down/right to clear i-1.
            for i in 1..<n {
                let minCenter = pos[i-1] + sizes[i-1]/2
                              + separation + sizes[i]/2
                if pos[i] < minCenter {
                    pos[i] = minCenter
                    moved = true
                }
            }
            // Clamp last to high.
            if let high {
                let lastFar = pos[n-1] + sizes[n-1]/2
                if lastFar > high {
                    pos[n-1] -= (lastFar - high)
                    moved = true
                }
            }
            // Backward: push i up/left to clear i+1.
            if n >= 2 {
                for i in (0..<(n-1)).reversed() {
                    let maxCenter = pos[i+1] - sizes[i+1]/2
                                  - separation - sizes[i]/2
                    if pos[i] > maxCenter {
                        pos[i] = maxCenter
                        moved = true
                    }
                }
            }
            // Clamp first to low.
            if let low {
                let firstNear = pos[0] - sizes[0]/2
                if firstNear < low {
                    pos[0] += (low - firstNear)
                    moved = true
                }
            }
            if !moved { break }
        }
        return pos
    }

    /// Clamp `center` so a `size`-sized box around it stays
    /// inside `bounds`. Used to keep callouts off non-canvas
    /// regions.
    private func clamp(_ center: CGPoint, size: CGSize, within bounds: CGRect) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        // If the callout is wider than the canvas, fall back to
        // canvas centre on that axis rather than producing a
        // negative valid range.
        let x: CGFloat
        if size.width >= bounds.width {
            x = bounds.midX
        } else {
            x = max(bounds.minX + halfW, min(bounds.maxX - halfW, center.x))
        }
        let y: CGFloat
        if size.height >= bounds.height {
            y = bounds.midY
        } else {
            y = max(bounds.minY + halfH, min(bounds.maxY - halfH, center.y))
        }
        return CGPoint(x: x, y: y)
    }

    private func preferredCenter(bracket: CGRect, size: CGSize,
                                  edge: HelpAnnotation.AnchorEdge,
                                  gap: CGFloat) -> CGPoint {
        switch edge {
        case .top:      return CGPoint(x: bracket.midX, y: bracket.minY - gap - size.height / 2)
        case .bottom:   return CGPoint(x: bracket.midX, y: bracket.maxY + gap + size.height / 2)
        case .leading:  return CGPoint(x: bracket.minX - gap - size.width / 2, y: bracket.midY)
        case .trailing: return CGPoint(x: bracket.maxX + gap + size.width / 2, y: bracket.midY)
        case .insideTop:    return CGPoint(x: bracket.midX, y: bracket.minY + gap + size.height / 2)
        case .insideBottom: return CGPoint(x: bracket.midX, y: bracket.maxY - gap - size.height / 2)
        case .insideCenter: return CGPoint(x: bracket.midX, y: bracket.midY)
        }
    }
}

/// Layout constants shared between the overlay (which
/// resolves positions) and `AnnotationView` (which draws the
/// bracket + arrow). Keeping them in one place avoids
/// arrow-to-bracket gap drift if either side is tweaked.
private enum HelpLayout {
    static let bracketInset: CGFloat = -4
    static let calloutGap: CGFloat = 14
    static let calloutMaxWidth: CGFloat = 260
}

/// Pass 1 of the overlay's two-pass rendering: the bracket
/// stroke around a single anchor. Rendered before any callout
/// so brackets always sit beneath cards. The bracket is
/// clamped to `bounds` so it never runs past the overlay's
/// edge for anchors flush against the sidebar / status-bar /
/// filmstrip perimeter.
private struct BracketView: View {
    let rect: CGRect
    let bounds: CGRect

    var body: some View {
        let expanded = rect.insetBy(dx: HelpLayout.bracketInset,
                                     dy: HelpLayout.bracketInset)
        let bracket = expanded.intersection(bounds)
        if !bracket.isNull, bracket.width > 0, bracket.height > 0 {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: bracket.width, height: bracket.height)
                .position(x: bracket.midX, y: bracket.midY)
                .allowsHitTesting(false)
        }
    }
}

/// Pass 2 of the overlay's two-pass rendering: arrow + label
/// callout for a single anchor. Drawn on top of every bracket
/// so a callout can never be obscured by a neighbour's bracket.
/// The callout is placed at `calloutCenter` (computed and
/// overlap-resolved by the parent overlay); the arrow connects
/// callout to bracket, picking endpoints that snap to the
/// nearest edges of each.
///
/// Callout size is measured via a GeometryReader background and
/// reported up through `reportSize` so the overlay can run a
/// second pass with collision-resolved positions. First frame:
/// callout is hidden (opacity 0) until a resolved centre
/// arrives.
private struct CalloutCardView: View {
    let rect: CGRect
    let annotation: HelpAnnotation
    let calloutCenter: CGPoint?
    let reportSize: (CGSize) -> Void

    @State private var currentSize: CGSize? = nil

    var body: some View {
        let bracket = rect.insetBy(dx: HelpLayout.bracketInset,
                                    dy: HelpLayout.bracketInset)
        ZStack(alignment: .topLeading) {
            // Arrow — endpoints picked from the actual callout
            // rect (which the overlay may have shifted to avoid
            // overlap), not from the anchor's edge. Falls back
            // to no arrow until a center is available. Skipped
            // when the callout is INSIDE the bracket — the
            // bracket-frames-callout pairing is self-evident.
            if let center = calloutCenter, let size = currentSize,
               !annotation.labelEdge.isInside {
                arrow(bracket: bracket,
                      callout: CGRect(x: center.x - size.width / 2,
                                      y: center.y - size.height / 2,
                                      width: size.width, height: size.height))
                    .stroke(Color.accentColor, style: StrokeStyle(
                        lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            calloutBody
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                currentSize = proxy.size
                                reportSize(proxy.size)
                            }
                            .onChange(of: proxy.size) { _, new in
                                currentSize = new
                                reportSize(new)
                            }
                    }
                )
                .opacity(calloutCenter == nil ? 0 : 1)
                .position(calloutCenter ?? .zero)
        }
        .allowsHitTesting(false)
    }

    private var calloutBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(annotation.title)
                .font(.callout.bold())
            Text(annotation.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !annotation.shortcuts.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(annotation.shortcuts, id: \.self) { s in
                        Text(s)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: HelpLayout.calloutMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    /// Straight arrow from the callout edge nearest the
    /// bracket to just inside the bracket, with a small
    /// arrowhead. Endpoints are picked from `callout`'s
    /// actual position (post-overlap-resolution) so the
    /// arrow stays connected even if the callout was shifted.
    private func arrow(bracket: CGRect, callout: CGRect) -> Path {
        var p = Path()
        let (from, to) = arrowEndpoints(bracket: bracket, callout: callout)
        p.move(to: from)
        p.addLine(to: to)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = max(sqrt(dx * dx + dy * dy), 0.0001)
        let ux = dx / len, uy = dy / len
        let headLen: CGFloat = 7
        let cosA: CGFloat = 0.866, sinA: CGFloat = 0.5  // 30°
        let leftX  = to.x - headLen * (ux * cosA - uy * sinA)
        let leftY  = to.y - headLen * (uy * cosA + ux * sinA)
        let rightX = to.x - headLen * (ux * cosA + uy * sinA)
        let rightY = to.y - headLen * (uy * cosA - ux * sinA)
        p.move(to: CGPoint(x: leftX, y: leftY))
        p.addLine(to: to)
        p.addLine(to: CGPoint(x: rightX, y: rightY))
        return p
    }

    private func arrowEndpoints(bracket: CGRect,
                                 callout: CGRect) -> (CGPoint, CGPoint) {
        switch annotation.labelEdge {
        case .top:
            // Callout is above bracket. From callout's bottom
            // edge at callout.midX → to bracket top centred
            // at bracket.midX. Use callout.midX so the arrow
            // origin tracks the (possibly shifted) callout.
            return (CGPoint(x: callout.midX, y: callout.maxY + 1),
                    CGPoint(x: bracket.midX, y: bracket.minY - 1))
        case .bottom:
            return (CGPoint(x: callout.midX, y: callout.minY - 1),
                    CGPoint(x: bracket.midX, y: bracket.maxY + 1))
        case .leading:
            return (CGPoint(x: callout.maxX + 1, y: callout.midY),
                    CGPoint(x: bracket.minX - 1, y: bracket.midY))
        case .trailing:
            return (CGPoint(x: callout.minX - 1, y: callout.midY),
                    CGPoint(x: bracket.maxX + 1, y: bracket.midY))
        case .insideTop, .insideBottom, .insideCenter:
            // Guarded out earlier — arrow not drawn for inside
            // edges. Return a zero-length placeholder to keep
            // the switch total.
            return (CGPoint(x: bracket.midX, y: bracket.midY),
                    CGPoint(x: bracket.midX, y: bracket.midY))
        }
    }
}

/// Lightweight flow-layout for the shortcut badges so they
/// wrap when a callout's width is constrained. SwiftUI didn't
/// ship a stock flow layout until macOS 16; this is the
/// macOS-15 compatible implementation.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        var total = CGSize.zero
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].isEmpty ? s.width
                        : rowWidth + spacing + s.width
            if needed > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(s)
            rowWidth = rows[rows.count - 1].reduce(0) { $0 + $1.width }
                     + CGFloat(rows[rows.count - 1].count - 1) * spacing
        }
        total.width = rows.map { row in
            row.reduce(0) { $0 + $1.width }
            + CGFloat(max(row.count - 1, 0)) * spacing
        }.max() ?? 0
        total.height = rows.reduce(0) { acc, row in
            acc + (row.map(\.height).max() ?? 0) + spacing
        } - spacing
        return total
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
