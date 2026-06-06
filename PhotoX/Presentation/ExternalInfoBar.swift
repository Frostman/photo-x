import SwiftUI

/// Bottom-leading chip on the external display showing the current pair
/// stem and `N of M` position. Auto-hides ~3 s after the last
/// navigation; reappears on the next displayedIndex change.
struct ExternalInfoBar: View {
    let state: ViewerState

    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?

    private static let visibleDuration: Duration = .seconds(3)

    var body: some View {
        let total = state.sortedEntries.count
        let displayed = state.displayedIndex
        let stem = state.displayedEntry?.stem ?? state.entry?.stem ?? ""
        let indexLabel = total > 0 ? "\(displayed + 1) of \(total)" : ""

        VStack {
            Spacer()
            HStack {
                HStack(spacing: 10) {
                    if !stem.isEmpty {
                        Text(stem)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .accessibilityIdentifier("externalDisplay.infoBar.stem")
                    }
                    if !indexLabel.isEmpty {
                        Text(indexLabel)
                            .font(.system(size: 16, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityIdentifier("externalDisplay.infoBar.index")
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: visible)
        .onChange(of: displayed) { _, _ in showAndScheduleHide() }
        .onChange(of: stem) { _, _ in showAndScheduleHide() }
        .onAppear { showAndScheduleHide() }
    }

    private func showAndScheduleHide() {
        visible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.visibleDuration)
            if !Task.isCancelled {
                visible = false
            }
        }
    }
}
