import SwiftUI

struct ContentView: View {
    @Bindable var state: ViewerState

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()

            if let image = state.currentImage {
                ImageCanvasView(image: image.cgImage, viewport: state.viewport)
                    .ignoresSafeArea()
            } else if state.isDecoding {
                ProgressView("Decoding…")
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
            } else if let message = state.errorMessage {
                VStack(spacing: 8) {
                    Text("Could not load image").font(.headline)
                    Text(message).foregroundStyle(.secondary).font(.callout)
                }
                .padding()
            } else {
                Text("No pair loaded")
                    .foregroundStyle(.secondary)
            }

            statusOverlay
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let image = state.currentImage {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(state.displayedVariant.displayName) • \(state.decoder.displayName) • \(Int(image.decodeMS)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(12)
                }
            }
        }
    }
}

#Preview {
    ContentView(state: ViewerState())
}
