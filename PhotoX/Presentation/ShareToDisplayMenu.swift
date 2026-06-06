import AppKit
import SwiftUI

/// Toolbar Share button + popover. Click opens a picker listing every
/// `DisplayTarget` (real external `NSScreen`s plus the synthetic dev
/// entry in DEBUG builds). The active row shows a checkmark when this
/// window is the active presenter on that target. Picking a target
/// silently takes over from any other presenting window.
///
/// The popover is driven by an external `isPresented` binding so the
/// `P` keyboard shortcut can open it from `ContentView.handleKeyDown`.
struct ShareToDisplayMenu: View {
    let state: ViewerState
    @Binding var isPresented: Bool

    private var coordinator: PresentationCoordinator { .shared }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Share",
                  systemImage: coordinator.isPresenting(state)
                    ? "square.and.arrow.up.fill"
                    : "square.and.arrow.up")
        }
        .controlSize(.small)
        .padding(.horizontal, 5)
        .help("Share (P) — present the current photo on an external display")
        .accessibilityIdentifier("toolbar.shareToDisplay")
        .accessibilityValue(coordinator.isPresenting(state) ? "presenting" : "idle")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ShareToDisplayPopover(state: state, isPresented: $isPresented)
        }
    }
}

private struct ShareToDisplayPopover: View {
    let state: ViewerState
    @Binding var isPresented: Bool

    private var coordinator: PresentationCoordinator { .shared }
    private var watcher: ExternalScreenWatcher { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if watcher.targets.isEmpty {
                emptyState
            } else {
                targetList
            }

            if coordinator.isPresenting(state) {
                Divider()
                stopRow
            }
        }
        .padding(.vertical, 8)
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private var header: some View {
        if let otherWindowTitle = otherPresenterWindowTitle() {
            VStack(alignment: .leading, spacing: 2) {
                Text("Presented by another window")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(otherWindowTitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No external displays detected")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Connect via HDMI / USB-C, or AirPlay → Use As Separate Display.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("share.emptyState")
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(watcher.targets) { target in
                Button {
                    if coordinator.isPresenting(state, on: target) {
                        coordinator.stopPresenting()
                    } else {
                        coordinator.startPresenting(state, on: target)
                    }
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .frame(width: 12)
                            .opacity(coordinator.isPresenting(state, on: target) ? 1 : 0)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.displayName)
                                .font(.body)
                            Text(resolutionLabel(for: target))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(UnstyledRowButtonStyle())
                .focusEffectDisabled()
                .accessibilityIdentifier("share.target.\(target.id)")
            }
        }
    }

    private var stopRow: some View {
        Button {
            coordinator.stopPresenting()
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle")
                    .frame(width: 12)
                Text("Stop Sharing")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(UnstyledRowButtonStyle())
        .focusEffectDisabled()
        .accessibilityIdentifier("share.stopSharing")
    }

    private func otherPresenterWindowTitle() -> String? {
        guard let active = coordinator.activePresenter, active !== state else { return nil }
        return coordinator.activePresenterWindowTitle()
    }

    private func resolutionLabel(for target: DisplayTarget) -> String {
        let w = Int(target.frame.width)
        let h = Int(target.frame.height)
        return "\(w) × \(h)"
    }
}

/// Button style that renders only the label — no background, no border,
/// no pressed/hover fill, no focus ring. The popover rows draw their own
/// content; SwiftUI's default ButtonStyle in popovers still paints a blue
/// keyboard-focus bar above and below each row, which reads as a
/// highlight even when no row is logically selected.
private struct UnstyledRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
