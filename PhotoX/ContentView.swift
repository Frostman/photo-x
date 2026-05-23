import AppKit
import SwiftUI

extension View {
    /// Conditionally apply a chain of modifiers. The transform is only
    /// invoked when `condition` is true; when false, the original view is
    /// returned unchanged. Used to detach the .onKeyPress chain entirely
    /// while a modal sheet is up — otherwise shortcuts intercept input
    /// before sheet controls see it, regardless of focus state.
    @ViewBuilder
    func conditional<V: View>(
        _ condition: Bool,
        transform: (Self) -> V
    ) -> some View {
        if condition { transform(self) } else { self }
    }
}

struct ContentView: View {
    @Bindable var state: ViewerState
    /// Optional — nil under `-photoxDisableSparkle` (DEBUG dev
    /// builds + E2E test runs) so the toolbar pill stays hidden
    /// regardless of any update state. Read-only here (we never
    /// need a SwiftUI binding into it), so no @Bindable.
    let updater: UpdaterController?
    @FocusState private var canvasFocused: Bool
    @State private var showHelp: Bool = false
    @State private var showJumpSheet: Bool = false
    @State private var copiedFlash: Bool = false
    @AppStorage(SettingsKey.appearance, store: AppDefaults.shared) private var appearanceRaw = SettingsKey.Defaults.appearance
    @AppStorage(SettingsKey.showCanvasLoadingIndicator, store: AppDefaults.shared) private var loadingIndicatorEnabled = SettingsKey.Defaults.showCanvasLoadingIndicator
    @State private var recents = RecentShoots.shared
    @State private var favorites = FavoriteShoots.shared
    /// Auto-detects mounted SD / CFExpress cards with DCIM shoots. Only
    /// active while the starter screen is on-screen; opening a shoot
    /// stops the watcher via emptyState.onDisappear.
    @State private var volumes = VolumeWatcher()
    @State private var folderStats = FolderStats()
    @State private var favoriteDropTarget: String? = nil
    @State private var showExportSheet: Bool = false
    @State private var exportRunner = ExportRunner.shared
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

            if showJumpSheet {
                // Overlay (not .sheet) so a tap on the dimmed
                // background dismisses, and the canvas's @FocusState
                // stays intact for arrow nav to resume immediately
                // after close. Matches HelpOverlay's pattern.
                JumpToView(state: state,
                           onDismiss: { showJumpSheet = false })
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(state: state, isPresented: $showExportSheet)
        }
        // When the export sheet is up, make ContentView completely
        // non-focusable so all key events are routed exclusively to the
        // sheet's controls. Just toggling canvasFocused to false isn't
        // enough — SwiftUI still keeps a focusable ContentView in the
        // responder chain, and its .onKeyPress modifiers intercept shortcut
        // keys before the TextField sees them.
        .focusable(!showExportSheet)
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onAppear { canvasFocused = true }
        .onChange(of: showExportSheet) { _, isShowing in
            canvasFocused = !isShowing
        }
        // Jump overlay focus handoff is fully handled inside
        // JumpToView.dismissCleanly via a synthetic mouse click on
        // the canvas — every SwiftUI @FocusState / AppKit
        // makeFirstResponder path we tried failed to restore arrow
        // nav after the overlay's TextField was destroyed. See the
        // comment block at JumpToView.simulateCanvasClick for why.
        // Detach the whole shortcut chain while the sheet is up — otherwise
        // .onKeyPress modifiers intercept everything before sheet controls
        // (TextField, etc.) get a chance.
        .conditional(!showExportSheet && !showJumpSheet) { view in
            // Canvas-action shortcuts only fire when a shoot is loaded.
            // Returning .ignored on the starter screen lets the OS
            // process the keystroke normally (beep, no side effects)
            // instead of toggling features against nil state OR
            // surfacing modals like the jump dialog out of context.
            // `?` (help) and Esc (dismiss help) stay always-available.
            let hasShoot = state.shoot != nil
            return view
                .onKeyPress(keys: ["z", "Z"]) { _ in
                    guard hasShoot else { return .ignored }
                    state.toggleRequestedVariant()
                    return .handled
                }
                .onKeyPress(keys: ["x", "X"]) { _ in
                    guard hasShoot else { return .ignored }
                    state.setViewportToFit()
                    return .handled
                }
                .onKeyPress(keys: ["d", "D"]) { _ in
                    guard hasShoot else { return .ignored }
                    state.cycleDecoder()
                    return .handled
                }
                .onKeyPress(keys: ["c", "C"]) { _ in
                    guard hasShoot else { return .ignored }
                    state.toggleClipping()
                    return .handled
                }
                .onKeyPress(keys: ["f", "F"]) { _ in
                    guard hasShoot else { return .ignored }
                    state.togglePeaking()
                    return .handled
                }
                .onKeyPress(keys: ["a", "A"]) { _ in
                    guard hasShoot else { return .ignored }
                    state.toggleAFOverlay()
                    return .handled
                }
                .onKeyPress(keys: ["b", "B"]) { _ in
                    guard hasShoot else { return .ignored }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.toggleSidebar()
                    }
                    return .handled
                }
                .onKeyPress(keys: ["t", "T"]) { _ in
                    guard hasShoot else { return .ignored }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.toggleFilmstrip()
                    }
                    return .handled
                }
                // Scoring. SwiftUI's onKeyPress matches against the TYPED character on
                // macOS, so Shift+1 arrives as "!" (not "1") — we register both forms.
                .onKeyPress(keys: ["1"]) { _ in guard hasShoot else { return .ignored }; state.toggleRating(1); return .handled }
                .onKeyPress(keys: ["2"]) { _ in guard hasShoot else { return .ignored }; state.toggleRating(2); return .handled }
                .onKeyPress(keys: ["3"]) { _ in guard hasShoot else { return .ignored }; state.toggleRating(3); return .handled }
                .onKeyPress(keys: ["4"]) { _ in guard hasShoot else { return .ignored }; state.toggleRating(4); return .handled }
                .onKeyPress(keys: ["5"]) { _ in guard hasShoot else { return .ignored }; state.toggleRating(5); return .handled }
                .onKeyPress(keys: ["!"]) { _ in guard hasShoot else { return .ignored }; state.toggleLabel("Red"); return .handled }
                .onKeyPress(keys: ["@"]) { _ in guard hasShoot else { return .ignored }; state.toggleLabel("Yellow"); return .handled }
                .onKeyPress(keys: ["#"]) { _ in guard hasShoot else { return .ignored }; state.toggleLabel("Green"); return .handled }
                .onKeyPress(keys: ["$"]) { _ in guard hasShoot else { return .ignored }; state.toggleLabel("Blue"); return .handled }
                .onKeyPress(keys: ["%"]) { _ in guard hasShoot else { return .ignored }; state.toggleLabel("Purple"); return .handled }
                .onKeyPress(keys: ["0"]) { _ in guard hasShoot else { return .ignored }; state.setRating(nil); return .handled }
                .onKeyPress(keys: ["r", "R"]) { _ in guard hasShoot else { return .ignored }; state.toggleReject(); return .handled }
                .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in
                    guard hasShoot else { return .ignored }
                    PerfTracker.begin("← key")
                    if press.modifiers.contains(.command) {
                        state.navigateByBurst(direction: -1)
                    } else if press.modifiers.contains(.option) {
                        // When collapse-bursts is on, ⌥arrow steps by
                        // 10 collapsed entries (one burst = one
                        // entry) so the filmstrip jumps a uniform
                        // 10 thumbs regardless of internal burst size.
                        if state.collapseBurstsActive {
                            state.navigate(byEntries: -10)
                        } else {
                            state.navigate(by: -10)
                        }
                    } else {
                        state.navigate(by: -1)
                    }
                    return .handled
                }
                .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in
                    guard hasShoot else { return .ignored }
                    PerfTracker.begin("→ key")
                    if press.modifiers.contains(.command) {
                        state.navigateByBurst(direction: 1)
                    } else if press.modifiers.contains(.option) {
                        if state.collapseBurstsActive {
                            state.navigate(byEntries: 10)
                        } else {
                            state.navigate(by: 10)
                        }
                    } else {
                        state.navigate(by: 1)
                    }
                    return .handled
                }
                .onKeyPress(.home) {
                    guard hasShoot else { return .ignored }
                    state.firstPair()
                    return .handled
                }
                .onKeyPress(.end) {
                    guard hasShoot else { return .ignored }
                    state.lastPair()
                    return .handled
                }
                .onKeyPress(KeyEquivalent("[")) {
                    guard hasShoot else { return .ignored }
                    state.previousUnrated()
                    return .handled
                }
                .onKeyPress(KeyEquivalent("]")) {
                    guard hasShoot else { return .ignored }
                    state.nextUnrated()
                    return .handled
                }
                .onKeyPress(keys: ["g", "G"]) { _ in
                    guard hasShoot else { return .ignored }
                    let raw = AppDefaults.shared.string(forKey: SettingsKey.gRejectScope)
                        ?? SettingsKey.Defaults.gRejectScope
                    let scope = GRejectScope(rawValue: raw) ?? .unrated
                    state.rejectBurstSiblings(scope: scope)
                    return .handled
                }
                .onKeyPress(keys: ["j", "J"]) { _ in
                    guard hasShoot else { return .ignored }
                    showJumpSheet = true
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
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .navigation) {
                // Same amber + dark-brown palette as the DEV pill baked
                // into AppIcon-Debug, so the titlebar badge reads as the
                // same "this is the dev build" cue at a glance.
                Text("DEV")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(Color(red: 0.20, green: 0.10, blue: 0.0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 1.00, green: 0.78, blue: 0.10), in: Capsule())
                    .help("Debug build — separate bundle ID (dev.frostman.PhotoX.debug), version forced to 0.0.0 so Sparkle always offers an upgrade to the latest release for popup testing, settings shared with production via AppDefaults")
            }
            #endif

            // Self-update pill — leftmost slot. Renders nothing
            // when no update is staged or while Sparkle is between
            // states. Same accent background for both .available
            // and .readyToInstall; icon changes between them.
            ToolbarItem(placement: .navigation) {
                if let updater,
                   let pill = updater.pillContent(currentShootURL: state.shoot?.folderURL) {
                    Button(action: pill.onTap) {
                        HStack(spacing: 4) {
                            Image(systemName: pill.icon)
                            Text(pill.label)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(pill.help)
                    .accessibilityIdentifier("toolbar.updatePill")
                }
            }

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

            // Pill cluster: failed-writes (red, only when non-empty)
            // sits LEFT of the export pill so its red colour catches
            // the eye first. Grouped into one ToolbarItemGroup
            // because the @ToolbarContentBuilder body caps at ~10
            // top-level items and we're at the limit.
            ToolbarItemGroup(placement: .primaryAction) {
                FailedWritesToolbarPill(state: state)
                if state.shoot != nil || exportRunner.isRunning {
                    ExportToolbarPill(state: state, showSheet: $showExportSheet)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWithPanel()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .controlSize(.small)
                .padding(.horizontal, 5)
                .help("Open folder of ARW + HIF/JPG pairs (⌘O)")
            }

            if state.shoot != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        closeShootGuarded()
                    } label: {
                        Label("Close Folder", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 5)
                    .help(exportRunner.isRunning
                          ? "Close shoot — will prompt to cancel the running export"
                          : "Close the current shoot and return to the starter screen")
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

            if let image = state.currentImage, let key = state.currentImageKey {
                // No .ignoresSafeArea() here — extending under the titlebar
                // pushes the photo's top edge behind the toolbar so the user
                // can't see the full frame at fit zoom. The backdrop above
                // still extends under, so visual continuity is preserved.
                ImageCanvasView(
                    image: image.cgImage,
                    // Stem of the pair the canvas is currently asked to
                    // render (NOT the displayed one — this drives WHICH
                    // texture upload is in flight). When the upload
                    // lands, onImageDisplayed fires with this stem and
                    // commitDisplayed syncs the rest of the UI to it.
                    imageToken: state.entry?.stem ?? "",
                    imageOrientation: image.orientation,
                    imageDecodeKey: key,
                    viewport: state.viewport,
                    showClipping: state.overlays.clipping,
                    showPeaking: state.overlays.focusPeaking,
                    onViewportChange: { vp, pz in
                        state.updateViewportFromCanvas(vp, pixelZoom: pz)
                    },
                    onImageDisplayed: { stem, pixelSize in
                        state.commitDisplayed(stem: stem, pixelSize: pixelSize)
                    }
                )
                .overlay {
                    if state.overlays.afPoints, state.displayedPixelSize != .zero {
                        // imagePixelSize is the DISPLAYED pair's size,
                        // NOT image.pixelSize — those can disagree for
                        // one frame during portrait↔landscape transitions
                        // (currentImage updates immediately on nav, but
                        // the AF rects are still for the still-bound
                        // previous image).
                        AFPointOverlay(
                            imagePixelSize: state.displayedPixelSize,
                            viewport: state.viewport,
                            regions: state.displayedAFRegions
                        )
                        .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if state.isLoadingDisplayedPair,
                       loadingIndicatorEnabled {
                        // Translucent disc so the spinner reads on any
                        // background. Centred automatically by .overlay.
                        ProgressView()
                            .controlSize(.large)
                            .progressViewStyle(.circular)
                            .padding(20)
                            .background(.black.opacity(0.4), in: Circle())
                            .foregroundStyle(.white)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("canvas.loadingIndicator")
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
            Text("Drop a folder of ARW + HIF/JPG pairs (or standalone HIF/JPG files) onto the window, or pick one.")
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
            if !volumes.cardFolders.isEmpty {
                cardsSection
            }
            if !visibleRecents.isEmpty {
                recentsSection
            }
            if !favorites.paths.isEmpty
                || !volumes.cardFolders.isEmpty
                || !visibleRecents.isEmpty {
                refreshCountsButton
            }
        }
        .onAppear {
            // Recount every time we return to the starter screen.
            folderStats.refresh(allStarterPaths)
            // Start watching for SD / CFExpress cards. Stops on
            // .onDisappear so we don't poll while viewing a shoot.
            volumes.start()
        }
        .onDisappear {
            volumes.stop()
        }
        .onChange(of: volumes.cardFolders) {
            // A freshly-detected card needs its pair-count pill
            // populated; the same folderStats machinery handles it.
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
        favorites.paths + volumes.cardFolders + visibleRecents
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


    /// Auto-detected shoot folders from mounted SD / CFExpress cards.
    /// Clicking the row opens the folder; the trailing eject button
    /// unmounts the whole card (mirrors Finder's sidebar). One clear
    /// placeholder sits where Recents has its star button so the
    /// pair-count pill + eject button align with the other sections.
    private var cardsSection: some View {
        section(title: "Cards") {
            ForEach(volumes.cardFolders, id: \.self) { path in
                pathRow(
                    path,
                    leading: { Color.clear.frame(width: 18, height: 20) },
                    trailing: {
                        pairCountPill(for: path)
                        Color.clear.frame(width: 20, height: 20)
                        rowButton(systemImage: "eject", tint: .secondary,
                                  help: "Eject card") {
                            ejectVolume(forCardPath: path)
                        }
                    }
                )
            }
        }
    }

    /// Walk a card path (`/Volumes/<NAME>/DCIM/<folder>`) two levels up
    /// to its volume root and ask the system to unmount + eject it.
    /// Drops the HIF bytes cache first so any mmap'd Data we held
    /// from a previous shoot view doesn't keep the volume busy. On
    /// failure (volume in use by another app) surfaces an NSAlert so
    /// the user knows nothing happened and why.
    private func ejectVolume(forCardPath path: String) {
        let volumeURL = URL(fileURLWithPath: path)
            .deletingLastPathComponent()   // /Volumes/<NAME>/DCIM
            .deletingLastPathComponent()   // /Volumes/<NAME>
        Task {
            await state.pipeline.previewBytes.clear()
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
                // VolumeWatcher's didUnmount observer will refresh the
                // Cards list automatically; nothing to do here.
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't eject \(volumeURL.lastPathComponent)"
                alert.informativeText = "macOS refused to unmount the card — it may still be in use by another app.\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
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
        .frame(maxWidth: 640, alignment: .leading)
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

    /// Confirm before closing the shoot if an export is in flight; on
    /// confirmation, cancel the export then close. Without confirmation the
    /// user could lose work-in-progress with an accidental click.
    private func closeShootGuarded() {
        guard exportRunner.isRunning else {
            state.closeShoot()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Export in progress"
        alert.informativeText = "An export to one or more destinations is still running. Closing this shoot now will cancel it and leave partially-copied files at the destinations."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stay")              // default = ⏎
        let destructive = alert.addButton(withTitle: "Cancel exports and close")
        destructive.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn {
            exportRunner.cancelAll()
            state.closeShoot()
        }
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
            guard let firstEntry = shoot.entries.first else {
                state.errorMessage = "No ARW + HIF/JPG pairs (or standalone HIF/JPG files) found in \(url.lastPathComponent)"
                return
            }
            // Restore the last-viewed entry if this path is a known
            // favorite or recent. Favorites take precedence (more
            // deliberate); both stores fall back to the first entry
            // silently if the saved stem no longer exists.
            let savedStem = FavoriteShoots.shared.lastEntry(for: path)
                         ?? RecentShoots.shared.lastEntry(for: path)
            let focus = savedStem
                .flatMap { stem in shoot.entries.first { $0.stem == stem } }
                ?? firstEntry
            await state.loadShoot(shoot, focus: focus)
        }
    }

    @ViewBuilder
    private var ratingBadge: some View {
        // Use displayedXMP (matches what's on the canvas) rather than
        // currentXMP (which would briefly show the navigation-intent
        // pair's rating on top of the still-bound previous image).
        // Sidebar already shows Decisions panel — don't duplicate the badge.
        if state.currentImage != nil, state.displayedXMP.hasDecision, !state.sidebarVisible {
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        if let label = state.displayedXMP.label, !label.isEmpty {
                            Circle()
                                .fill(LabelChip.color(for: label))
                                .frame(width: 10, height: 10)
                        }
                        if state.displayedXMP.isReject {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        } else if let stars = state.displayedXMP.starCount {
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
                    // Use displayedEntry so the pill identifies what the
                    // user actually sees, not the (briefly different)
                    // navigation intent during a rapid arrow burst.
                    if let entry = state.displayedEntry { stemPill(entry: entry) }
                    Spacer()
                    Text(statusText(image: image))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                        .accessibilityIdentifier("canvas.statusText")
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func stemPill(entry: PhotoEntry) -> some View {
        let _ = { PerfTracker.mark("stemPill rendering (stem=\(entry.stem))") }()
        let burst = state.burstPosition(for: entry.stem)
        let _ = { PerfTracker.mark("stemPill: burstPosition done") }()
        HStack(spacing: 8) {
            if let shoot = state.shoot, shoot.count > 1 {
                Text("\(state.displayedIndex + 1)/\(shoot.count)")
                    .frame(width: indexSlotWidth(for: shoot.count), alignment: .leading)
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityIdentifier("canvas.stemPill.indexLabel")
            }
            Text(copiedFlash ? "Copied path" : entry.stem)
                .foregroundStyle(.white.opacity(0.85))
                .onTapGesture { copyPath(for: entry) }
                .help("Click to copy ARW path (HIF/JPG path if ARW is missing)")
                .accessibilityIdentifier("canvas.stemPill.stem")
            Text(filesBadge)
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityIdentifier("canvas.stemPill.files")
            if let b = burst {
                Text("\(b.index)/\(b.total) burst")
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityIdentifier("canvas.stemPill.burst")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: Capsule())
        // No container-level identifier: SwiftUI propagates the
        // parent identifier to every accessibility descendant,
        // clobbering the per-Text identifiers we need for tests.
    }

    /// What files exist on disk for the current entry. When both HIF
    /// and JPG are present we already prefer HIF in the model layer,
    /// so the badge reflects that — "ARW+HIF" not "ARW+HIF+JPG".
    private var filesBadge: String {
        let files = state.currentEntryFiles
        switch (files.arw, files.hif, files.jpg) {
        case (true,  true,  _):     return "ARW+HIF"
        case (true,  false, true):  return "ARW+JPG"
        case (true,  false, false): return "ARW"
        case (false, true,  _):     return "HIF"
        case (false, false, true):  return "JPG"
        case (false, false, false): return ""
        }
    }

    private func copyPath(for entry: PhotoEntry) {
        let fm = FileManager.default
        let url: URL? = {
            if let raw = entry.rawURL, fm.fileExists(atPath: raw.path) { return raw }
            if fm.fileExists(atPath: entry.previewURL.path) { return entry.previewURL }
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

    /// Recursive depth-first search for the `ImageCanvasNSView`
    /// inside an arbitrary NSView tree. Used by the jump-overlay
    /// dismiss path to reset AppKit's firstResponder to the canvas
    /// (SwiftUI's @FocusState doesn't restore AppKit focus after
    /// the overlay's TextField is destroyed — same effect as the
    /// user manually clicking the canvas).
    static func findCanvasNSView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is ImageCanvasNSView { return view }
        for sub in view.subviews {
            if let found = findCanvasNSView(in: sub) { return found }
        }
        return nil
    }

    /// Reserve enough horizontal space for the largest possible "N/M" string
    /// in this shoot, so the pair name lands at a stable x as N changes.
    private func indexSlotWidth(for count: Int) -> CGFloat {
        let digits = String(count).count
        let chars = digits * 2 + 1               // "N/M" character count
        return CGFloat(chars) * 7.5 + 2          // monospaced caption ≈ 7-8pt/char
    }

    private func statusText(image: DecodedImage) -> String {
        // Format-honest preview label: "HEIF" for HIF/HEIF/HEIC,
        // "JPEG" for JPG/JPEG. RAW stays "RAW".
        let variantLabel: String = {
            if state.displayedVariant == .raw { return "RAW" }
            return (state.displayedEntry?.hasJPGPreview ?? false) ? "JPEG" : "HEIF"
        }()
        var parts: [String] = [variantLabel]
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
            state.errorMessage = "No ARW + HIF/JPG pair (or standalone HIF/JPG) found in dropped items"
            return false
        }
        Task { await state.loadShoot(shoot, focus: focus) }
        return true
    }
}

#Preview {
    ContentView(state: ViewerState(), updater: nil)
}
