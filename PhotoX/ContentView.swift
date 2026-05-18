import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var state: ViewerState
    @FocusState private var canvasFocused: Bool
    @State private var showHelp: Bool = false
    @State private var copiedFlash: Bool = false
    @AppStorage(SettingsKey.appearance) private var appearanceRaw = SettingsKey.Defaults.appearance
    @State private var recents = RecentShoots.shared
    @State private var favorites = FavoriteShoots.shared
    @State private var folderStats = FolderStats()
    @State private var favoriteDropTarget: String? = nil
    @Environment(\.openSettings) private var openSettings

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    canvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Sidebar/filmstrip/statusbar are gated on having a shoot
                    // loaded — when the window is in the empty state, there's
                    // nothing for them to show, so we collapse to the full
                    // canvas. Once a folder is loaded they follow defaults.
                    if state.shoot != nil {
                        StatusBarView(state: state)
                    }
                    if state.filmstripVisible && state.shoot != nil {
                        FilmstripView(state: state)
                            .transition(.move(edge: .bottom))
                    }
                }
                if state.sidebarVisible && state.shoot != nil {
                    SidebarView(state: state)
                        .transition(.move(edge: .trailing))
                }
            }

            if showHelp {
                HelpOverlay(onDismiss: { showHelp = false })
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onAppear { canvasFocused = true }
        .onKeyPress(keys: ["z", "Z"]) { _ in
            state.toggleRequestedVariant()
            return .handled
        }
        .onKeyPress(keys: ["x", "X"]) { _ in
            state.setViewportToFit()
            return .handled
        }
        .onKeyPress(keys: ["d", "D"]) { _ in
            state.cycleDecoder()
            return .handled
        }
        .onKeyPress(keys: ["c", "C"]) { _ in
            state.toggleClipping()
            return .handled
        }
        .onKeyPress(keys: ["f", "F"]) { _ in
            state.togglePeaking()
            return .handled
        }
        .onKeyPress(keys: ["a", "A"]) { _ in
            state.toggleAFOverlay()
            return .handled
        }
        .onKeyPress(keys: ["b", "B"]) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                state.toggleSidebar()
            }
            return .handled
        }
        .onKeyPress(keys: ["t", "T"]) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                state.toggleFilmstrip()
            }
            return .handled
        }
        // Scoring. SwiftUI's onKeyPress matches against the TYPED character on
        // macOS, so Shift+1 arrives as "!" (not "1") — we register both forms.
        .onKeyPress(keys: ["1"]) { _ in state.toggleRating(1); return .handled }
        .onKeyPress(keys: ["2"]) { _ in state.toggleRating(2); return .handled }
        .onKeyPress(keys: ["3"]) { _ in state.toggleRating(3); return .handled }
        .onKeyPress(keys: ["4"]) { _ in state.toggleRating(4); return .handled }
        .onKeyPress(keys: ["5"]) { _ in state.toggleRating(5); return .handled }
        .onKeyPress(keys: ["!"]) { _ in state.toggleLabel("Red"); return .handled }
        .onKeyPress(keys: ["@"]) { _ in state.toggleLabel("Yellow"); return .handled }
        .onKeyPress(keys: ["#"]) { _ in state.toggleLabel("Green"); return .handled }
        .onKeyPress(keys: ["$"]) { _ in state.toggleLabel("Blue"); return .handled }
        .onKeyPress(keys: ["%"]) { _ in state.toggleLabel("Purple"); return .handled }
        .onKeyPress(keys: ["0"]) { _ in state.setRating(nil); return .handled }
        .onKeyPress(keys: ["r", "R"]) { _ in state.toggleReject(); return .handled }
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in
            PerfTracker.begin("← key")
            let step = press.modifiers.contains(.option) ? 10 : 1
            state.navigate(by: -step)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in
            PerfTracker.begin("→ key")
            let step = press.modifiers.contains(.option) ? 10 : 1
            state.navigate(by: step)
            return .handled
        }
        .onKeyPress(.home) {
            state.firstPair()
            return .handled
        }
        .onKeyPress(.end) {
            state.lastPair()
            return .handled
        }
        .onKeyPress(KeyEquivalent("?")) {
            withAnimation(.easeInOut(duration: 0.12)) { showHelp.toggle() }
            return .handled
        }
        .onKeyPress(.escape) {
            guard showHelp else { return .ignored }
            withAnimation(.easeInOut(duration: 0.12)) { showHelp = false }
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Always populate the principal slot — when it returns
                // EmptyView, SwiftUI collapses the toolbar's three-region
                // layout and the .primaryAction items drift toward center
                // instead of hugging the right edge. The text is wrapped in
                // a plain Button so clicking it opens the file picker
                // (equivalent to clicking Open Folder).
                Button {
                    openWithPanel()
                } label: {
                    Group {
                        if let url = state.shoot?.folderURL {
                            Text((url.path as NSString).abbreviatingWithTildeInPath)
                                .help(url.path)
                        } else {
                            Text("— no folder open —")
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .help("Open another folder (⌘O)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWithPanel()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .controlSize(.small)
                .padding(.horizontal, 5)
                .help("Open folder of ARW + HIF pairs (⌘O)")
            }

            if state.shoot != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        state.closeShoot()
                    } label: {
                        Label("Close Folder", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 5)
                    .help("Close the current shoot and return to the starter screen")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    appearanceRaw = appearance.next.rawValue
                } label: {
                    Label(appearance.displayName, systemImage: appearance.toolbarSymbol)
                }
                .controlSize(.small)
                .padding(.horizontal, 5)
                .help("Theme: \(appearance.displayName) — click to cycle System → Light → Dark")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
                .padding(.horizontal, 5)
                .help("Open Settings (⌘,)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { showHelp.toggle() }
                } label: {
                    Label("Shortcuts", systemImage: "questionmark.circle")
                }
                .controlSize(.small)
                .padding(.horizontal, 5)
                .help("Show keyboard shortcuts (?)")
            }

            // Pane toggles are only meaningful when a shoot is loaded. Hide
            // them on the starter screen entirely so the toolbar reads as
            // "Open · theme · ?" instead of "Open · theme · ? · grayed · grayed".
            if state.shoot != nil {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $state.filmstripVisible) {
                        Label("Filmstrip", systemImage: "rectangle.split.3x1")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .padding(.horizontal, 5)
                    .help("Toggle filmstrip (T)")
                }

                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $state.sidebarVisible) {
                        Label("Sidebar", systemImage: "sidebar.right")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .padding(.horizontal, 5)
                    .help("Toggle sidebar (B)")
                }
            }
        }
    }

    private var canvas: some View {
        ZStack {
            // Dark canvas backdrop is intentional behind a photo (industry
            // convention — neutralises perceived white balance) but on light
            // theme it makes the empty/error/loading states a solid black
            // rectangle with no chrome. Use the dark backdrop only when an
            // image is actively on screen.
            //
            // NOT ignoring safe area on purpose: when this view did, SwiftUI
            // extended the enclosing HStack's bounds up to match, which made
            // the sibling sidebar (sharing that HStack) also stretch under
            // the titlebar. Letting the backdrop respect the safe area keeps
            // both the canvas and the sidebar below the toolbar.
            canvasBackdrop

            if let image = state.currentImage {
                // No .ignoresSafeArea() here — extending under the titlebar
                // pushes the photo's top edge behind the toolbar so the user
                // can't see the full frame at fit zoom. The backdrop above
                // still extends under, so visual continuity is preserved.
                ImageCanvasView(
                    image: image.cgImage,
                    viewport: state.viewport,
                    showClipping: state.overlays.clipping,
                    showPeaking: state.overlays.focusPeaking,
                    onViewportChange: { vp, pz in
                        state.updateViewportFromCanvas(vp, pixelZoom: pz)
                    }
                )
                .overlay {
                    if state.overlays.afPoints {
                        AFPointOverlay(
                            imagePixelSize: image.pixelSize,
                            viewport: state.viewport,
                            regions: state.currentAFRegions
                        )
                        .allowsHitTesting(false)
                    }
                }
            } else if state.isDecoding {
                ProgressView("Decoding…")
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
            } else if let message = state.errorMessage {
                VStack(spacing: 8) {
                    Text("Could not load image").font(.headline)
                    Text(message).foregroundStyle(.secondary).font(.callout)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                emptyState
            }

            statusOverlay
            decodingPill
            ratingBadge
        }
    }

    private var canvasBackdrop: Color {
        if state.currentImage != nil {
            return Color(white: 0.07)
        }
        return Color(nsColor: .windowBackgroundColor)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("No folder open")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Drop a folder of ARW + HIF pairs onto the window, or pick one.")
                .font(.callout)
                .foregroundStyle(.secondary.opacity(0.7))
            Button {
                openWithPanel()
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            if !favorites.paths.isEmpty {
                favoritesSection
            }
            if !visibleRecents.isEmpty {
                recentsSection
            }
            if !favorites.paths.isEmpty || !visibleRecents.isEmpty {
                refreshCountsButton
            }
        }
        .onAppear {
            // Recount every time we return to the starter screen.
            folderStats.refresh(allStarterPaths)
        }
    }

    /// Recent paths minus anything already in Favorites, capped at 10.
    /// Favoriting a recent moves it into the Favorites section instead of
    /// duplicating across both lists.
    private var visibleRecents: [String] {
        recents.paths
            .filter { !favorites.contains($0) }
            .prefix(10)
            .map { $0 }
    }

    private var allStarterPaths: [String] {
        favorites.paths + visibleRecents
    }

    private var refreshCountsButton: some View {
        Button {
            folderStats.refresh(allStarterPaths)
        } label: {
            Label("Refresh counts", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Re-scan each folder and update the pair-count pills")
        .padding(.top, 4)
    }

    private var favoritesSection: some View {
        section(title: "Favorites") {
            ForEach(favorites.paths, id: \.self) { path in
                pathRow(
                    path,
                    leading: { favoriteDragHandle(for: path) },
                    trailing: {
                        pairCountPill(for: path)
                        // Star slot placeholder so the X column aligns with
                        // Recent rows (which have a star button in this slot).
                        Color.clear.frame(width: 20, height: 20)
                        rowButton(systemImage: "xmark", tint: .secondary,
                                  help: "Remove from favorites") {
                            favorites.remove(path)
                        }
                    }
                )
                // Insertion indicator is an OVERLAY, not a sibling above the
                // row, so the row's bounds don't shift when the user hovers a
                // drop target. A shifting bounds means the cursor can end up
                // outside the drop destination at the moment of release and
                // SwiftUI silently ignores the drop until you click again.
                .overlay(alignment: .top) {
                    if favoriteDropTarget == path {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .padding(.horizontal, -2)
                            .offset(y: -3)
                            .transition(.opacity)
                    }
                }
                .dropDestination(
                    for: String.self,
                    action: { dropped, _ in
                        guard let source = dropped.first, source != path else { return false }
                        favorites.move(source, before: path)
                        favoriteDropTarget = nil
                        return true
                    },
                    isTargeted: { isTargeted in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            if isTargeted {
                                favoriteDropTarget = path
                            } else if favoriteDropTarget == path {
                                favoriteDropTarget = nil
                            }
                        }
                    }
                )
            }
        }
    }

    /// Grip icon. Only this is draggable; the rest of the row stays a normal
    /// path button so the visual doesn't suggest "drop a file into this folder".
    private func favoriteDragHandle(for path: String) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 20)
            .contentShape(Rectangle())
            .help("Drag to rearrange")
            .draggable(path) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
    }


    private var recentsSection: some View {
        section(title: "Recent") {
            ForEach(visibleRecents, id: \.self) { path in
                pathRow(
                    path,
                    // Empty leading slot the same width as the favorites'
                    // drag handle so folder icons line up across sections.
                    leading: { Color.clear.frame(width: 18, height: 20) },
                    trailing: {
                        pairCountPill(for: path)
                        rowButton(systemImage: "star", tint: .secondary,
                                  help: "Add to favorites") {
                            favorites.add(path)
                        }
                        rowButton(systemImage: "xmark", tint: .secondary,
                                  help: "Remove from recent") {
                            recents.remove(path)
                        }
                    }
                )
            }
        }
    }

    /// Section wrapper: smallCaps header + rows in a left-aligned 520pt column.
    @ViewBuilder
    private func section<Content: View>(
        title: String, @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            rows()
        }
        .padding(.top, 6)
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// Path row: optional caller-supplied leading content (drag handle for
    /// favorites), clickable folder + path in the middle, trailing buttons.
    @ViewBuilder
    private func pathRow<Leading: View, Trailing: View>(
        _ path: String,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 6) {
            leading()
            Button {
                openPath(path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .help(path)
            Spacer()
            trailing()
        }
    }

    private func rowButton(
        systemImage: String, tint: Color, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// "N/M" pill next to each favorite/recent — N pairs with an XMP sidecar,
    /// M pairs total. Fixed minWidth so the trailing column lines up across
    /// rows regardless of which state each row is in.
    @ViewBuilder
    private func pairCountPill(for path: String) -> some View {
        let state = folderStats.stats[path] ?? .unknown
        Group {
            switch state {
            case .unknown:
                Color.clear
            case .loading:
                ProgressView()
                    .controlSize(.mini)
            case .ok(let count):
                Text("\(count.withXMP)/\(count.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help("\(count.withXMP) of \(count.total) pairs have an XMP sidecar")
            case .inaccessible:
                Text("missing")
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12), in: Capsule())
                    .help("Folder is missing or cannot be accessed")
            }
        }
        .frame(minWidth: 60, alignment: .trailing)
    }

    private func openWithPanel() {
        Task {
            guard let (shoot, focus) = OpenPanelCoordinator.runShootPicker() else { return }
            await state.loadShoot(shoot, focus: focus)
        }
    }

    private func openPath(_ path: String) {
        Task {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else {
                state.errorMessage = "Folder no longer exists: \(path)"
                return
            }
            let shoot = ShootScanner.scan(folder: url)
            guard let focus = shoot.pairs.first else {
                state.errorMessage = "No ARW + HIF pairs found in \(url.lastPathComponent)"
                return
            }
            await state.loadShoot(shoot, focus: focus)
        }
    }

    @ViewBuilder
    private var ratingBadge: some View {
        // Sidebar already shows Decisions panel — don't duplicate the badge.
        if state.currentImage != nil, state.currentXMP.hasDecision, !state.sidebarVisible {
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        if let label = state.currentXMP.label, !label.isEmpty {
                            Circle()
                                .fill(LabelChip.color(for: label))
                                .frame(width: 10, height: 10)
                        }
                        if state.currentXMP.isReject {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        } else if let stars = state.currentXMP.starCount {
                            StarsView(count: stars)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
                }
                .padding(12)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let image = state.currentImage {
            VStack {
                Spacer()
                HStack {
                    if let pair = state.pair { stemPill(pair: pair) }
                    Spacer()
                    Text(statusText(image: image))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func stemPill(pair: PhotoPair) -> some View {
        HStack(spacing: 8) {
            if let shoot = state.shoot, shoot.count > 1 {
                Text("\(state.currentIndex + 1)/\(shoot.count)")
                    .frame(width: indexSlotWidth(for: shoot.count), alignment: .leading)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Text(copiedFlash ? "Copied path" : pair.stem)
                .foregroundStyle(.white.opacity(0.85))
                .onTapGesture { copyPath(for: pair) }
                .help("Click to copy ARW path (HIF if ARW is missing)")
            Text(filesBadge)
                .foregroundStyle(.white.opacity(0.45))
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: Capsule())
    }

    private var filesBadge: String {
        let files = state.currentPairFiles
        var parts: [String] = []
        switch (files.arw, files.hif) {
        case (true, true):  parts.append("ARW+HIF")
        case (true, false): parts.append("ARW")
        case (false, true): parts.append("HIF")
        case (false, false): break
        }
        if files.xmp { parts.append("+XMP") }
        return parts.joined()
    }

    private func copyPath(for pair: PhotoPair) {
        let fm = FileManager.default
        let url: URL? = {
            if fm.fileExists(atPath: pair.rawURL.path) { return pair.rawURL }
            if fm.fileExists(atPath: pair.heifURL.path) { return pair.heifURL }
            return nil
        }()
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        copiedFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            await MainActor.run { copiedFlash = false }
        }
    }

    /// Reserve enough horizontal space for the largest possible "N/M" string
    /// in this shoot, so the pair name lands at a stable x as N changes.
    private func indexSlotWidth(for count: Int) -> CGFloat {
        let digits = String(count).count
        let chars = digits * 2 + 1               // "N/M" character count
        return CGFloat(chars) * 7.5 + 2          // monospaced caption ≈ 7-8pt/char
    }

    private func statusText(image: DecodedImage) -> String {
        var parts: [String] = [state.displayedVariant.displayName]
        if state.displayedVariant == .raw {
            parts.append(state.decoder.displayName)
        }
        parts.append(zoomLabel)
        if state.overlays.clipping {
            parts.append("CLIP")
        }
        if state.overlays.focusPeaking {
            parts.append("PEAK")
        }
        if state.overlays.afPoints {
            parts.append("AF")
        }
        return parts.joined(separator: " • ")
    }

    private var zoomLabel: String {
        let pct = state.currentPixelZoom * 100
        if pct >= 100 {
            return "\(Int(pct.rounded()))%"
        } else {
            return String(format: "%.0f%%", pct)
        }
    }

    @ViewBuilder
    private var decodingPill: some View {
        if state.isDecoding && state.currentImage != nil && state.displayedVariant != state.requestedVariant {
            VStack {
                HStack {
                    Spacer()
                    Label("Decoding \(state.requestedVariant.displayName)…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.monospaced())
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                Spacer()
            }
            .padding(12)
        }
    }

    @discardableResult
    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let (shoot, focus) = ShootScanner.resolve(droppedURLs: urls) else {
            state.errorMessage = "No ARW + HIF pair found in dropped items"
            return false
        }
        Task { await state.loadShoot(shoot, focus: focus) }
        return true
    }
}

#Preview {
    ContentView(state: ViewerState())
}
