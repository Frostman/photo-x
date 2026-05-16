import SwiftUI

struct HelpOverlay: View {
    let onDismiss: () -> Void

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let label: String
    }

    private let sections: [(title: String, items: [Shortcut])] = [
        ("Image variant", [
            .init(keys: "Z", label: "Toggle HEIF ↔ RAW"),
            .init(keys: "D", label: "Cycle decoder (ImageIO / LibRaw)"),
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
            .init(keys: "B", label: "Toggle sidebar (histogram, etc.)"),
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
                                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
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
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: 6)
    }
}

#Preview {
    HelpOverlay(onDismiss: {})
        .frame(width: 800, height: 600)
}
