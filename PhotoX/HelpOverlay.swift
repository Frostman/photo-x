import SwiftUI

struct HelpOverlay: View {
    let onDismiss: () -> Void

    /// Card background only changes when the user is on the Light appearance.
    /// On Dark we keep the original near-black to match the previous look.
    @Environment(\.colorScheme) private var colorScheme

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.13)
            : Color(nsColor: .windowBackgroundColor)
    }

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let label: String
    }

    private let sections: [(title: String, items: [Shortcut])] = [
        ("Scoring", [
            .init(keys: "1 – 5", label: "Set star rating; same key again clears (writes xmp:Rating)"),
            .init(keys: "⇧ 1 – 5", label: "Toggle color label: Red / Yellow / Green / Blue / Purple (writes xmp:Label)"),
            .init(keys: "0", label: "Clear rating"),
            .init(keys: "R", label: "Reject (xmp:Rating = -1); R again un-rejects"),
        ]),
        ("Image variant", [
            .init(keys: "Z", label: "Toggle HEIF ↔ RAW"),
            .init(keys: "D", label: "Cycle decoder (ImageIO / LibRaw)"),
        ]),
        ("Navigation", [
            .init(keys: "← / →", label: "Previous / next pair in the shoot"),
            .init(keys: "⌥ ← / →", label: "Skip 10 pairs"),
            .init(keys: "Home / End", label: "Jump to first / last pair"),
        ]),
        ("View", [
            .init(keys: "X", label: "Fit to window"),
            .init(keys: "⌘0", label: "Fit to window"),
            .init(keys: "Double-click", label: "Toggle fit ↔ 100%"),
            .init(keys: "Pinch / ⌘ + scroll", label: "Zoom"),
            .init(keys: "Drag / Two-finger scroll", label: "Pan"),
        ]),
        ("Overlays", [
            .init(keys: "C", label: "Clipping zebra — magenta = blown highlights (any channel ≥ 99%), blue = crushed shadows (max ≤ 2%)"),
            .init(keys: "F", label: "Focus peaking — orange tint over in-focus edges (Sobel on luminance)"),
            .init(keys: "A", label: "AF point overlay — yellow box where the camera focused (read from MakerNotes via exiftool)"),
            .init(keys: "B", label: "Toggle sidebar (histogram, etc.)"),
            .init(keys: "T", label: "Toggle filmstrip (thumbnails with star/label badges)"),
        ]),
        ("Files", [
            .init(keys: "⌘O", label: "Open ARW + HIF pair"),
            .init(keys: "Drag & drop", label: "Open files or folder"),
        ]),
        ("Help", [
            .init(keys: "?", label: "Show / hide this help"),
            .init(keys: "Esc", label: "Dismiss this help"),
        ]),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            card
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title3.bold())
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(section.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(item.keys)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                    .frame(minWidth: 80, alignment: .leading)
                                Text(item.label)
                                    .foregroundStyle(.primary.opacity(0.85))
                                Spacer(minLength: 0)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: 6)
    }
}

#Preview {
    HelpOverlay(onDismiss: {})
        .frame(width: 800, height: 600)
}
