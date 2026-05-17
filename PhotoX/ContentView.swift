import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var state: ViewerState
    @FocusState private var canvasFocused: Bool
    @State private var showHelp: Bool = false
    @State private var copiedFlash: Bool = false

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
                if let url = state.shoot?.folderURL {
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .help(url.path)
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
                .help("Open folder of ARW + HIF pairs (⌘O)")
            }

            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $state.filmstripVisible) {
                    Label("Filmstrip", systemImage: "rectangle.split.3x1")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .padding(.horizontal, 5)
                .help("Toggle filmstrip (T)")
                .disabled(state.shoot == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $state.sidebarVisible) {
                    Label("Sidebar", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .padding(.horizontal, 5)
                .help("Toggle sidebar (B)")
                .disabled(state.shoot == nil)
            }
        }
    }

    private var canvas: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()

            if let image = state.currentImage {
                ImageCanvasView(
                    image: image.cgImage,
                    viewport: state.viewport,
                    showClipping: state.overlays.clipping,
                    showPeaking: state.overlays.focusPeaking,
                    onViewportChange: { vp, pz in
                        state.updateViewportFromCanvas(vp, pixelZoom: pz)
                    }
                )
                .ignoresSafeArea()
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
            helpHint
            ratingBadge
        }
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
        }
    }

    private func openWithPanel() {
        Task {
            guard let (shoot, focus) = OpenPanelCoordinator.runShootPicker() else { return }
            await state.loadShoot(shoot, focus: focus)
        }
    }

    @ViewBuilder
    private var helpHint: some View {
        VStack {
            HStack {
                Text("? for shortcuts")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.4), in: Capsule())
                Spacer()
            }
            .padding(12)
            Spacer()
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
