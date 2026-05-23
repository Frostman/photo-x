import SwiftUI

/// Red toolbar pill that appears when one or more XMP writes have
/// failed after exhausting the coordinator's retry policy. Sits to
/// the LEFT of the Export pill in the toolbar's primaryAction
/// cluster. Click opens a separate (non-modal) window showing each
/// failed stem with a Retry All button.
///
/// **Why prominent**: saving culling decisions is the project's #1
/// promise. A silent toast wouldn't cut it; the pill stays visible
/// until the user resolves it (retry succeeds, or Dismiss All).
struct FailedWritesToolbarPill: View {
    @Bindable var state: ViewerState
    @State private var windowController = FailedWritesWindowController()

    var body: some View {
        let count = state.failedXMPWrites.count
        if count > 0 {
            Button {
                windowController.show(state: state)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                    Text("\(count) write\(count == 1 ? "" : "s") failed")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.85), in: Capsule())
                .overlay(
                    Capsule().stroke(Color.red, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Some rating / label writes didn't make it to disk. Click to review and retry.")
        }
    }
}
