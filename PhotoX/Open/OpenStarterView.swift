import SwiftUI
import AppKit

/// First workspace tab — the starter / open-folder surface.
/// Hosts the "Open Folder…" button, the Favorites list, the
/// auto-detected SD / CFExpress Cards list, and the Recents
/// list. Always reachable from the toolbar tab picker
/// regardless of whether a shoot is currently loaded —
/// switching here does NOT close the active shoot.
///
/// Extracted from `ContentView.emptyState` when the Open tab
/// was promoted to a first-class workspace mode so future
/// open-related surfaces (cloud sources, server folders, …)
/// have a single home that doesn't bloat ContentView.
@MainActor
struct OpenStarterView: View {
    @Bindable var state: ViewerState
    /// Workspace-mode binding so clicking a row for the
    /// already-loaded shoot can short-circuit the reload and
    /// just hop the tab to View.
    @Binding var mode: WorkspaceMode
    @State private var recents = RecentShoots.shared
    @State private var favorites = FavoriteShoots.shared
    /// Auto-detects mounted SD / CFExpress cards with DCIM shoots.
    /// Started in `.onAppear`, stopped in `.onDisappear` so we
    /// don't poll while the user is on another workspace tab.
    @State private var volumes = VolumeWatcher()
    @State private var folderStats = FolderStats()
    @State private var favoriteDropTarget: String? = nil
    /// SwiftUI's open-window action for the main scene. Used by
    /// the ⌥-click branch on path rows to spawn a new window
    /// rather than reuse the current one.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary.opacity(0.4))
            Text(state.shoot == nil ? "No folder open" : "Open another folder")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Drop a folder of ARW + HIF/JPG pairs (or standalone HIF/JPG files) onto the window, or pick one.")
                .font(.callout)
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            Button {
                openWithPanel()
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            .helpAnchor(.openFolderButton)

            // Sections render unconditionally so the user sees
            // every category on a fresh launch (and the help
            // overlay's section callouts always have an anchor
            // to point at). Each section body shows a small
            // italic placeholder when its list is empty.
            favoritesSection
                .helpAnchor(.openFavorites)
            cardsSection
                .helpAnchor(.openCards)
            recentsSection
                .helpAnchor(.openRecents)
            if !favorites.paths.isEmpty
                || !volumes.cardFolders.isEmpty
                || !visibleRecents.isEmpty {
                refreshCountsButton
            }
        }
        .onAppear {
            // Recount every time we enter the Open tab.
            folderStats.refresh(allStarterPaths)
            // Start watching for SD / CFExpress cards. Stops on
            // .onDisappear so we don't poll while on other tabs.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Whole-tab help anchor: the multi-window callout sits
        // centred at the bottom-inside of this bracket so it
        // doesn't crowd the per-section right-gutter callouts
        // above (Favorites / Cards / Recents).
        .helpAnchor(.openMultiWindow)
        // Drag-and-drop is handled at the ContentView level
        // (window-wide), so a folder dropped on the tab works
        // here too without a per-view duplicate handler.
    }

    // MARK: Sections

    @ViewBuilder
    private var favoritesSection: some View {
        section(title: "Favorites") {
            if favorites.paths.isEmpty {
                emptyPlaceholder("No favorites yet — star a recent folder below to pin it.")
            } else {
                favoritesRows
            }
        }
    }

    private var favoritesRows: some View {
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
    @ViewBuilder
    private var cardsSection: some View {
        section(title: "Cards") {
            if volumes.cardFolders.isEmpty {
                emptyPlaceholder("No SD or CFExpress cards mounted.")
            } else {
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
    }

    /// Walk a card path (`/Volumes/<NAME>/DCIM/<folder>`) two levels
    /// up to its volume root and ask the system to unmount + eject
    /// it. If any open PhotoX window (across the whole app, not
    /// just this view's window) has a shoot loaded from this card,
    /// surface a "close the shoot first" alert and abort — closing
    /// shoots is left to the user, not automated. On unmount
    /// failure surfaces an `NSAlert` (volume in use by another
    /// app, etc.).
    private func ejectVolume(forCardPath path: String) {
        let volumeURL = URL(fileURLWithPath: path)
            .deletingLastPathComponent()   // /Volumes/<NAME>/DCIM
            .deletingLastPathComponent()   // /Volumes/<NAME>
        Task {
            let affected = WindowRegistry.shared.windows(withShootOn: volumeURL)
            if !affected.isEmpty {
                let n = affected.count
                let shootNoun = n == 1 ? "shoot is" : "shoots are"
                let alert = NSAlert()
                alert.messageText = "Can't eject '\(volumeURL.lastPathComponent)'"
                alert.informativeText = "\(n) \(shootNoun) open on this card. Close \(n == 1 ? "it" : "them") in \(n == 1 ? "its" : "their") window\(n == 1 ? "" : "s") before ejecting."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
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

    @ViewBuilder
    private var recentsSection: some View {
        section(title: "Recent") {
            if visibleRecents.isEmpty {
                emptyPlaceholder("No recent folders yet — opened folders land here.")
            } else {
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
    }

    // MARK: Helpers

    /// Recent paths minus anything already in Favorites, capped at 10.
    /// Favoriting a recent moves it into the Favorites section instead
    /// of duplicating across both lists.
    private var visibleRecents: [String] {
        recents.paths
            .filter { !favorites.contains($0) }
            .prefix(10)
            .map { $0 }
    }

    private var allStarterPaths: [String] {
        favorites.paths + volumes.cardFolders + visibleRecents
    }

    /// Small italic note rendered inside an empty section so
    /// the user knows the section exists and what'll show up
    /// once it has content. Indented to line up with where
    /// real rows' path text begins (leading 18pt slot + 6pt
    /// spacing + ~16pt folder icon + 6pt spacing ≈ 46pt).
    private func emptyPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .italic()
            .foregroundStyle(.secondary.opacity(0.7))
            .padding(.leading, 46)
            .padding(.vertical, 2)
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
            .help("\(path)\nHold ⌥ to open in a new window")
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
        let pillState = folderStats.stats[path] ?? .unknown
        Group {
            switch pillState {
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

    // MARK: Open actions

    private func openWithPanel() {
        Task {
            guard let (shoot, focus) = OpenPanelCoordinator.runShootPicker() else { return }
            // Check dedup BEFORE flipping mode — if the shoot is
            // already open in another window, ShootOpener will
            // focus that window and we must stay on Open here
            // (flipping to View first causes a visible flicker).
            if WindowRegistry.shared.window(forShootPath: shoot.folderURL.path) == nil {
                mode = .view
            }
            _ = await ShootOpener.open(
                shoot: shoot, focus: focus, requestedTarget: .targetState(state))
        }
    }

    private func openPath(_ path: String) {
        // Modifier-click convention (mirrors the File →
        // Open Recent submenu): ⌥ at click-time routes to a
        // new window instead of reusing this one. Read via
        // NSEvent so a plain SwiftUI Button action can
        // branch on the live modifier state.
        if NSEvent.modifierFlags.contains(.option) {
            openPathInNewWindow(path)
            return
        }
        // See `openWithPanel` for why we check dedup before
        // touching mode. Sync check + sync mode write keeps the
        // View tab appearance flicker-free.
        if WindowRegistry.shared.window(forShootPath: path) == nil {
            mode = .view
        }
        Task {
            _ = await ShootOpener.open(
                path: path, requestedTarget: .targetState(state))
        }
    }

    /// ⌥-click branch from `openPath`. Dedup first — if some
    /// window already holds this shoot, focus it instead of
    /// spawning a fresh window the user would have to close.
    /// Otherwise enqueue the path so the next `WindowRoot`
    /// scene picks it up and ask SwiftUI for a new window.
    private func openPathInNewWindow(_ path: String) {
        if let existing = WindowRegistry.shared.window(forShootPath: path) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        WindowRegistry.shared.enqueuePendingShoot(.path(path))
        openWindow(id: WindowID.main)
    }

}
