import SwiftUI

struct ContentView: View {
    @Bindable var state: ViewerState
    @FocusState private var canvasFocused: Bool
    @State private var showHelp: Bool = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.sidebarVisible {
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
        .onKeyPress(.leftArrow) {
            state.previousPair()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            state.nextPair()
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
                Text("Drop an ARW + HIF pair, or press ⌘O")
                    .foregroundStyle(.secondary)
            }

            statusOverlay
            decodingPill
            helpHint
            ratingBadge
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
        if state.currentImage != nil, state.currentXMP.hasDecision {
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        if state.currentXMP.isReject {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        } else if let stars = state.currentXMP.starCount {
                            StarsView(count: stars)
                        }
                        if let label = state.currentXMP.label, !label.isEmpty {
                            LabelChip(label: label)
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
                    if let pair = state.pair {
                        Text(stemAndIndex(pair: pair))
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
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

    private func stemAndIndex(pair: PhotoPair) -> String {
        guard let shoot = state.shoot, shoot.count > 1 else { return pair.stem }
        return "\(pair.stem)   \(state.currentIndex + 1)/\(shoot.count)"
    }

    private func statusText(image: DecodedImage) -> String {
        var parts: [String] = [state.displayedVariant.displayName]
        if state.displayedVariant == .raw {
            parts.append(state.decoder.displayName)
        }
        parts.append("\(Int(image.decodeMS)) ms")
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
