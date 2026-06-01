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

/// Bundles the reactions that keep `WorkspaceMode` consistent:
/// atomic focus transition on tab change, auto-revert when the
/// shoot closes, and the single parameterised notification
/// observer wired to the View menu's tab shortcuts. Extracted
/// because folding the modifiers inline pushed ContentView's
/// body chain past Swift's expression-type-check budget.
private struct ModeWiring: ViewModifier {
    @Binding var mode: WorkspaceMode
    /// Workspace-wide shared focus. Setting it to a new value
    /// is a single atomic transition that SwiftUI propagates
    /// to AppKit's responder chain — unlike two independent
    /// FocusStates, where dropping one doesn't auto-engage
    /// the other.
    var focus: FocusState<WorkspaceFocus?>.Binding
    @Binding var showHelp: Bool
    @Binding var showAnnotationHelp: Bool
    let shootMissing: Bool
    /// Identity used to filter targeted workspace-switch
    /// notifications. Each window's `WorkspaceSwitchRequest`
    /// carries its target `ViewerState`; observers ignore
    /// requests aimed at other windows.
    let state: ViewerState

    func body(content: Content) -> some View {
        content
            .onChange(of: mode, initial: true) { _, newMode in
                let tab = workspaceTab(for: newMode)
                focus.wrappedValue = tab.defaultFocus
                // Auto-show the annotated help overlay if
                // this tab has been updated since the user
                // last visited it. Recording lastSeen at
                // show-time (rather than dismiss-time) means
                // the user only sees the auto-show once per
                // bump per tab even if they immediately
                // dismiss — and they can still re-open with
                // `?` at any time.
                let key = SettingsKey.helpLastSeen(for: newMode)
                // Per-bundle so dev and prod track their own
                // "seen" history — bumping `helpVersion` in
                // a dev build doesn't silently mark the
                // same tab "already seen" in prod.
                let lastSeen = LocalAppDefaults.shared.integer(forKey: key)
                if tab.helpVersion > lastSeen, !showAnnotationHelp {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showAnnotationHelp = true
                    }
                    LocalAppDefaults.shared.set(tab.helpVersion, forKey: key)
                }
            }
            .onChange(of: shootMissing) { _, gone in
                if gone {
                    // Close any open help overlay — without a
                    // shoot there's no UI for it to point at.
                    if showHelp { showHelp = false }
                    if showAnnotationHelp { showAnnotationHelp = false }
                    // If the current tab requires a shoot, fall
                    // back to the first tab that doesn't
                    // (today: `.open`). Config-driven so new
                    // tabs automatically participate.
                    if workspaceTab(for: mode).requiresShoot,
                       let fallback = workspaceTabs.first(where: { !$0.requiresShoot }) {
                        mode = fallback.mode
                    }
                } else if mode == .open {
                    // Shoot just loaded while user was on the
                    // Open tab — hop to View so the photo they
                    // just opened actually shows. Respect their
                    // explicit choice if they're already on
                    // View / Export.
                    mode = .view
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .photoxSwitchWorkspace)) { notif in
                guard let req = notif.object as? WorkspaceSwitchRequest else { return }
                // Filter by target identity so a switch aimed at
                // window A doesn't yank window B's tab.
                guard req.target === state else { return }
                // Tabs that require a shoot become no-ops on
                // the starter screen.
                if workspaceTab(for: req.mode).requiresShoot, shootMissing { return }
                mode = req.mode
            }
    }
}

struct ContentView: View {
    @Bindable var state: ViewerState
    /// Optional — nil under `-photoxDisableSparkle` (DEBUG dev
    /// builds + E2E test runs) so the toolbar pill stays hidden
    /// regardless of any update state. Read-only here (we never
    /// need a SwiftUI binding into it), so no @Bindable.
    let updater: UpdaterController?
    /// Single shared focus state for every focusable target
    /// across the workspace. Each tab's focusable element
    /// (canvas container, export TextField, future tabs') binds
    /// via `.focused($focus, equals: .someCase)`. Setting
    /// `focus = .other` is the atomic transition SwiftUI needs
    /// to keep AppKit's responder chain in sync across tab
    /// switches. See `WorkspaceFocus` for the case list.
    @FocusState private var focus: WorkspaceFocus?
    /// AppKit-level keyboard monitor (installed in `.onAppear`).
    /// All app-defined keybindings flow through `handleKeyDown`
    /// regardless of SwiftUI focus state — `.onKeyPress` was
    /// unreliable across workspace mode switches (focusable
    /// container loses its AppKit responder claim after the
    /// export pane's TextField releases SwiftUI focus, leaving
    /// arrow nav dead until the user clicks). NSEvent monitors
    /// sit *above* the responder chain so they fire even when
    /// nothing's focused.
    @State private var keyMonitor: Any?
    /// Flat keyboard-shortcuts reference card (`HelpOverlay`).
    /// Triggered from menu bar's Help → Keyboard Shortcuts
    /// (⌘?). NOT bound to `?` anymore — that key now opens
    /// the annotated overlay below.
    @State private var showHelp: Bool = false
    /// Annotated-screenshot help overlay with brackets +
    /// inline shortcut hints pointing at the live UI.
    /// Triggered by `?` and the toolbar `?` button.
    @State private var showAnnotationHelp: Bool = false
    @State private var helpAnchorStore = HelpAnchorStore()
    @State private var showJumpSheet: Bool = false
    @State private var copiedFlash: Bool = false
    /// Title-bar "Copied path" flash, kept distinct from the canvas
    /// stem pill's `copiedFlash` so a click on either doesn't visually
    /// echo through the other surface.
    @State private var titleCopiedFlash: Bool = false
    @AppStorage(SettingsKey.appearance, store: AppDefaults.shared) private var appearanceRaw = SettingsKey.Defaults.appearance
    @AppStorage(SettingsKey.showCanvasLoadingIndicator, store: AppDefaults.shared) private var loadingIndicatorEnabled = SettingsKey.Defaults.showCanvasLoadingIndicator
    // recents / favorites / volumes / folderStats / favoriteDropTarget
    // moved into `OpenStarterView` along with the starter UI.
    /// Drives the segmented toolbar picker. `.open` shows the
    /// starter screen, `.view` shows the canvas + sidebar +
    /// filmstrip + status bar, `.export` swaps the content area
    /// for `ExportPaneView`. Singletons (ExportSettings.shared,
    /// ExportRunner.shared) preserve the export's state across
    /// switches, so toggling is free.
    @State private var mode: WorkspaceMode = .open
    @State private var exportRunner = ExportRunner.shared
    @Environment(\.openSettings) private var openSettings

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        ZStack {
            switch mode {
            case .open:
                OpenStarterView(state: state, mode: $mode)
            case .view:
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        canvas
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .helpAnchor(.canvas)
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
            case .export:
                // The pane's own state lives in singletons
                // (ExportSettings.shared, ExportRunner.shared)
                // so re-mount loses nothing. Focus is driven
                // by the shared `$focus` binding via
                // ModeWiring's mode-change handler, not via
                // an `onAppear` trick — that's why the .id(mode)
                // remount workaround is no longer needed.
                ExportPaneView(state: state, focus: $focus)
            }

            if showHelp {
                HelpOverlay(onDismiss: { showHelp = false })
            }

            if showAnnotationHelp {
                HelpAnnotationOverlay(
                    store: helpAnchorStore,
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            showAnnotationHelp = false
                        }
                    }
                )
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
        // Named coordinate space so `.helpAnchor(_:)` modifiers
        // throughout the tree can report frames in a single
        // window-relative basis, which the annotated-help
        // overlay reads to position its brackets + callouts.
        .coordinateSpace(name: "help")
        .onPreferenceChange(HelpAnchorPreferenceKey.self) { rects in
            helpAnchorStore.rects = rects
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .photoxShowKeyboardShortcuts)) { _ in
            withAnimation(.easeInOut(duration: 0.12)) {
                showHelp.toggle()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        // Always focusable — the focusable container stays in
        // the SwiftUI focus chain across mode transitions, so
        // AppKit's responder chain isn't disrupted on Export →
        // View. The `.conditional(mode == .view && …)` gating
        // below is what actually prevents the onKeyPress chain
        // from intercepting keys destined for the export
        // TextField (gated by mode, not by focusability).
        .focusable(true)
        .focusEffectDisabled()
        .focused($focus, equals: .canvas)
        .onAppear {
            // ModeWiring's `onChange(of: mode, initial: true)`
            // sets focus to the launch tab's defaultFocus on
            // mount — no separate canvas focus init needed.
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .modifier(ModeWiring(mode: $mode,
                             focus: $focus,
                             showHelp: $showHelp,
                             showAnnotationHelp: $showAnnotationHelp,
                             shootMissing: state.shoot == nil,
                             state: state))
        // Keybindings are routed through the NSEvent local
        // monitor installed in `.onAppear` (see `installKeyMonitor`
        // + `handleKeyDown` below). SwiftUI's `.onKeyPress`
        // chain was too fragile across workspace mode switches —
        // the focusable container reliably failed to re-engage
        // AppKit's responder chain after the export pane's
        // TextField released SwiftUI focus.
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
                // instead of hugging the right edge. Clicking the path
                // copies it to the clipboard (briefly flashes "Copied path")
                // — handy for sharing the shoot location.
                Button {
                    if let url = state.shoot?.folderURL {
                        copyShootPathToClipboard(url)
                    }
                } label: {
                    Group {
                        if titleCopiedFlash {
                            Text("Copied path")
                        } else if let url = state.shoot?.folderURL {
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
                .disabled(state.shoot == nil)
                .help("Click to copy the shoot folder path")
            }

            // Pill cluster: failed-writes (red, only when non-empty)
            // sits LEFT of the workspace tab picker so its red colour
            // catches the eye first. Grouped into one ToolbarItemGroup
            // because the @ToolbarContentBuilder body caps at ~10
            // top-level items and we're at the limit. The tab picker
            // is both the View/Export switch AND the live export-
            // progress display, so a separate standalone export pill
            // is no longer needed.
            ToolbarItemGroup(placement: .primaryAction) {
                FailedWritesToolbarPill(state: state)
                // Picker is always present — Open tab is always
                // enabled and View / Export grey out when no
                // shoot is loaded.
                WorkspaceTabPicker(state: state, mode: $mode)
            }

            // The standalone "Open Folder" toolbar item was removed
            // when the Open tab was promoted to a workspace tab —
            // the Open tab segment in the picker (plus the principal
            // folder-path button above) cover this affordance.

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
                // Toggle (not Button) so the toolbar adopts the same
                // on/off highlight that the Filmstrip / Sidebar
                // toggles get — visible cue that the overlay is up.
                // Custom Binding wraps the set in `withAnimation` so
                // the overlay fade matches the click cadence.
                Toggle(isOn: Binding(
                    get: { showAnnotationHelp },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            showAnnotationHelp = newValue
                        }
                    }
                )) {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .padding(.horizontal, 5)
                .help("Show annotated help (?). Help → Keyboard Shortcuts for the full reference list (⌘?).")
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
            }
            // No "empty state" branch — the starter screen is now
            // its own workspace tab (`OpenStarterView`). The View
            // tab is gated on `state.shoot != nil` via the picker,
            // so this canvas only renders when a shoot exists.

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

    // Starter-screen helpers (emptyState, favoritesSection,
    // cardsSection, recentsSection, pathRow, pairCountPill,
    // ejectVolume, openWithPanel, openPath, etc.) moved to
    // `OpenStarterView`.

    /// Confirm before closing if there are unsaved XMP writes (the
    /// coordinator's pending queue OR the failed-writes pill) OR an
    /// export is in flight. Two independent alerts: XMP first, then
    /// export. If the user backs out at either step, nothing is
    /// discarded — both side effects are deferred until every
    /// confirmation passes.
    private func closeShootGuarded() {
        Task { @MainActor in
            let xmpNeedsConfirm = await state.hasUnsavedXMPWork()
            if xmpNeedsConfirm, !confirmDiscardUnsavedXMP() { return }
            if exportRunner.isRunning {
                let alert = NSAlert()
                alert.messageText = "Export in progress"
                alert.informativeText = "An export to one or more destinations is still running. Closing this shoot now will cancel it and leave partially-copied files at the destinations."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Stay")          // default = ⏎
                let destructive = alert.addButton(withTitle: "Cancel exports and close")
                destructive.hasDestructiveAction = true
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                exportRunner.cancelAll()
            }
            if xmpNeedsConfirm {
                await state.discardAllUnsavedXMPState()
            }
            state.closeShoot()
        }
    }

    /// XMP-side close-shoot alert. Tailors its text to whether the
    /// loss is failed writes (pill) or in-flight pendings or both.
    private func confirmDiscardUnsavedXMP() -> Bool {
        let failed = state.failedXMPWrites.count
        let alert = NSAlert()
        alert.messageText = "Unsaved XMP writes"
        alert.informativeText = failed > 0
            ? "\(failed) XMP write\(failed == 1 ? "" : "s") to sidecar file\(failed == 1 ? "" : "s") failed and \(failed == 1 ? "is" : "are") waiting in the failures list. Closing this shoot will discard \(failed == 1 ? "it" : "them") along with any rating or label changes still being saved to disk."
            : "Some XMP writes are still being saved to disk. Closing this shoot now will discard them — your most recent rating and label changes for this shoot would be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stay")              // default = ⏎
        let destructive = alert.addButton(withTitle: "Discard and close")
        destructive.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    // openWithPanel + openPath moved to OpenStarterView.

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

    private func copyShootPathToClipboard(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        titleCopiedFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            await MainActor.run { titleCopiedFlash = false }
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

    // MARK: Keyboard monitor

    /// Installs an `NSEvent` local monitor that handles every
    /// app-defined keybinding regardless of SwiftUI focus state.
    /// This bypasses the cross-mode focus restoration bug —
    /// `.onKeyPress` only fires when SwiftUI's focusable
    /// container is the active responder, which it intermittently
    /// fails to be after the export pane's TextField releases
    /// focus.
    ///
    /// Returns `nil` from the closure to consume the event,
    /// `event` to let AppKit continue its normal dispatch
    /// (menu shortcuts, TextField input, etc.).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // `@MainActor` on the closure puts the NSEvent in
        // MainActor scope from the moment AppKit delivers it,
        // so handleKeyDown's MainActor-isolated state access
        // doesn't need a `MainActor.assumeIsolated` bridge
        // (which would warn under Swift 6 strict concurrency
        // because NSEvent isn't Sendable).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor event in
            handleKeyDown(event)
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Single-point dispatch for every app keybinding. Decides
    /// based on `event` + current `mode` + modal flags + focus
    /// (TextField input must pass through). Mirrors what the
    /// previous `.onKeyPress` chain did 1:1.
    @MainActor
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // 1. TextField / TextEditor input must pass through —
        //    typing into the project-name field or JumpToView's
        //    search field would otherwise eat the key.
        if NSApp.keyWindow?.firstResponder is NSText { return event }

        // Resolve via the ASCII-capable layout so shortcuts fire regardless of the
        // active input source (e.g. pressing physical R while Russian is selected
        // still triggers "r"-bound shortcuts instead of producing "К").
        let chars = ASCIIKeyboardLayout.characters(for: event)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 2. Esc dismisses help / annotated-help overlays.
        if event.keyCode == 53 {  // kVK_Escape
            if showHelp || showAnnotationHelp {
                withAnimation(.easeInOut(duration: 0.12)) {
                    showHelp = false
                    showAnnotationHelp = false
                }
                return nil
            }
            return event
        }

        // 3. `?` toggles the annotated help overlay (no
        //    modifiers — ⌘? goes to the menu's Keyboard
        //    Shortcuts item via the standard menu path).
        if chars == "?" && !mods.contains(.command) {
            withAnimation(.easeInOut(duration: 0.12)) {
                showAnnotationHelp.toggle()
            }
            return nil
        }

        // 4. Tab on the Export tab focuses the project-name
        //    field. Export's default focus is `nil` so the
        //    user can browse the pane without keys being
        //    captured by the field; Tab is the explicit opt-in.
        if event.keyCode == 48, mods.isEmpty, mode == .export {  // kVK_Tab
            focus = .exportProjectName
            return nil
        }

        // 5. Beyond this, only the View tab gets keybindings,
        //    and only with a shoot loaded + no modal overlay
        //    up. JumpToView eats its own keys via its TextField.
        guard mode == .view,
              !showJumpSheet,
              state.shoot != nil else { return event }

        // 6. Cmd-modified arrows are ours (burst nav). Other
        //    Cmd combos belong to menus — don't intercept.
        let isArrow = (event.keyCode == 123 || event.keyCode == 124)
        if mods.contains(.command) && !isArrow { return event }

        // 7. Special keys by keyCode (arrows, home, end).
        switch event.keyCode {
        case 123:  // LeftArrow
            PerfTracker.begin("← key")
            if mods.contains(.command) {
                state.navigateByBurst(direction: -1)
            } else if mods.contains(.option) {
                if state.collapseBurstsActive {
                    state.navigate(byEntries: -10)
                } else {
                    state.navigate(by: -10)
                }
            } else {
                state.navigate(by: -1)
            }
            return nil
        case 124:  // RightArrow
            PerfTracker.begin("→ key")
            if mods.contains(.command) {
                state.navigateByBurst(direction: 1)
            } else if mods.contains(.option) {
                if state.collapseBurstsActive {
                    state.navigate(byEntries: 10)
                } else {
                    state.navigate(by: 10)
                }
            } else {
                state.navigate(by: 1)
            }
            return nil
        case 115:  // Home (also fn+LeftArrow — keycode is Home,
                   //       but `.function` is set in the modifier
                   //       flags, so a plain `isEmpty` check
                   //       misses it).
            if mods.subtracting(.function).isEmpty {
                state.firstPair()
                return nil
            }
            return event
        case 119:  // End (also fn+RightArrow — see comment above).
            if mods.subtracting(.function).isEmpty {
                state.lastPair()
                return nil
            }
            return event
        default:
            break
        }

        // 8. Character keys. `event.characters` is the typed
        //    character (Shift+1 → "!", etc.) so we match both
        //    base and shifted forms for each binding.
        switch chars {
        case "x":
            state.toggleRequestedVariant(); return nil
        case "X":
            state.cycleDecoder(); return nil
        case "c", "C":
            state.toggleClipping(); return nil
        case "f", "F":
            state.togglePeaking(); return nil
        case "a", "A":
            state.toggleAFOverlay(); return nil
        case "b", "B":
            withAnimation(.easeInOut(duration: 0.15)) {
                state.toggleSidebar()
            }
            return nil
        case "t", "T":
            withAnimation(.easeInOut(duration: 0.15)) {
                state.toggleFilmstrip()
            }
            return nil
        case "r", "R":
            state.toggleReject(); return nil
        case "g", "G":
            let raw = AppDefaults.shared.string(forKey: SettingsKey.gRejectScope)
                ?? SettingsKey.Defaults.gRejectScope
            let scope = GRejectScope(rawValue: raw) ?? .unrated
            state.rejectBurstSiblings(scope: scope)
            return nil
        case "j", "J":
            showJumpSheet = true; return nil
        case "[":
            state.previousUnrated(); return nil
        case "]":
            state.nextUnrated(); return nil
        case "1": state.toggleRating(1); return nil
        case "2": state.toggleRating(2); return nil
        case "3": state.toggleRating(3); return nil
        case "4": state.toggleRating(4); return nil
        case "5": state.toggleRating(5); return nil
        case "0": state.setRating(nil); return nil
        // Shift+digit → typed character is "!@#$%" — colour labels.
        case "!": state.toggleLabel("Red"); return nil
        case "@": state.toggleLabel("Yellow"); return nil
        case "#": state.toggleLabel("Green"); return nil
        case "$": state.toggleLabel("Blue"); return nil
        case "%": state.toggleLabel("Purple"); return nil
        default:
            return event
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
        Task {
            // Drop happened on THIS window — target its state directly
            // so the load doesn't race against an unrelated frontmost.
            await ShootOpener.open(shoot: shoot, focus: focus, requestedTarget: .targetState(state))
        }
        return true
    }
}

#Preview {
    ContentView(state: ViewerState(), updater: nil)
}
