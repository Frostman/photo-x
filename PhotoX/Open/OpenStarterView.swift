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
    @State private var recents = RecentShoots.shared
    @State private var favorites = FavoriteShoots.shared
    /// Auto-detects mounted SD / CFExpress cards with DCIM shoots.
    /// Started in `.onAppear`, stopped in `.onDisappear` so we
    /// don't poll while the user is on another workspace tab.
    @State private var volumes = VolumeWatcher()
    @State private var folderStats = FolderStats()
    @State private var favoriteDropTarget: String? = nil

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

            if !favorites.paths.isEmpty {
                favoritesSection
                    .helpAnchor(.openFavorites)
            }
            if !volumes.cardFolders.isEmpty {
                cardsSection
                    .helpAnchor(.openCards)
            }
            if !visibleRecents.isEmpty {
                recentsSection
                    .helpAnchor(.openRecents)
            }
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
        // Drag-and-drop is handled at the ContentView level
        // (window-wide), so a folder dropped on the tab works
        // here too without a per-view duplicate handler.
    }

    // MARK: Sections

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

}
