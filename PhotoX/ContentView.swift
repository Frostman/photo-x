import SwiftUI

struct ContentView: View {
    @Bindable var state: ViewerState
    @FocusState private var canvasFocused: Bool

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()

            if let image = state.currentImage {
                ImageCanvasView(
                    image: image.cgImage,
                    viewport: state.viewport,
                    onViewportChange: { vp, pz in
                        state.updateViewportFromCanvas(vp, pixelZoom: pz)
                    }
                )
                .ignoresSafeArea()
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
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let image = state.currentImage {
            VStack {
                Spacer()
                HStack {
                    if let pair = state.pair {
                        Text(pair.stem)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
                    Spacer()
                    Text("\(state.displayedVariant.displayName) • \(state.decoder.displayName) • \(Int(image.decodeMS)) ms • \(zoomLabel)")
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
        let files = PairFinder.expand(urls)
        guard let pair = PairFinder.firstPair(in: files) else {
            state.errorMessage = "No ARW + HIF pair found in dropped items"
            return false
        }
        Task { await state.loadPair(pair) }
        return true
    }
}

#Preview {
    ContentView(state: ViewerState())
}
