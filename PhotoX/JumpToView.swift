import AppKit
import SwiftUI

/// Modal-style overlay invoked by `j`. Lets the user jump to an
/// entry by 1-based index OR by stem name with substring auto-
/// completion. If every stem in the current shoot shares an
/// alphabetic prefix (e.g. `DSC0…`) we pre-fill it so the user
/// only types the variable part.
///
/// Rendered as a ZStack overlay (not a SwiftUI `.sheet`) for two
/// reasons: tap-outside dismissal, and the canvas's @FocusState
/// stays uncorrupted so arrow nav resumes immediately after the
/// overlay closes — `.sheet` steals + loses focus in a way that
/// requires a manual click to recover.
struct JumpToView: View {
    @Bindable var state: ViewerState
    let onDismiss: () -> Void

    @State private var query: String = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        ZStack {
            // Dim background — tap anywhere outside the card dismisses.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissCleanly() }

            card
        }
        .transition(.opacity)
        // `.contain` keeps every child (TextField, suggestion
        // buttons, Cancel/Jump buttons) independently accessible to
        // VoiceOver and XCUITest while still creating a single AX
        // element for the ZStack — without this,
        // `.accessibilityIdentifier` propagates to every leaf and
        // both `app.otherElements["jumpTo.overlay"]` and
        // `app.textFields["jumpTo.query"]` find the wrong element
        // (or none). See the matching note in HelpAnnotationOverlay.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("jumpTo.overlay")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Jump to").font(.headline)
                Spacer()
                Button(action: dismissCleanly) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            // Placeholder moved out so the auto-filled common prefix
            // doesn't hide it.
            Text("Enter an index (1–\(state.shoot?.count ?? 0)) or a stem name.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onSubmit { jumpAndDismiss() }
                .onAppear {
                    if query.isEmpty { query = commonStemPrefix() }
                    // Defer the focus claim by one runloop tick — the
                    // canvas's @FocusState transitions to false on the
                    // same SwiftUI render that opens this overlay, so
                    // a same-tick claim races and loses on macOS.
                    DispatchQueue.main.async {
                        queryFocused = true
                    }
                }
                .accessibilityIdentifier("jumpTo.query")

            // Up to 8 suggestions — substring match (case-insensitive)
            // over the shoot's stems, in name-sort order.
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self) { stem in
                        Button {
                            query = stem
                            jumpAndDismiss()
                        } label: {
                            Text(stem)
                                .font(.callout.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { dismissCleanly() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Jump") { jumpAndDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasJumpTarget)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: 6)
    }

    // MARK: - logic

    private var allStems: [String] {
        state.shoot?.entries.map(\.stem) ?? []
    }

    private var suggestions: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Array(allStems.prefix(8)) }
        return allStems
            .filter { $0.localizedCaseInsensitiveContains(trimmed) }
            .prefix(8)
            .map { $0 }
    }

    private var hasJumpTarget: Bool {
        resolveTargetIndex() != nil
    }

    private func jumpAndDismiss() {
        if let idx = resolveTargetIndex() {
            state.navigate(to: idx)
        }
        dismissCleanly()
    }

    /// Synthesize a click on the canvas at dismiss time. Every
    /// SwiftUI / AppKit `@FocusState` / `makeFirstResponder` path
    /// we tried failed to restore canvas focus after the overlay's
    /// TextField was destroyed — but a real click on the canvas
    /// always recovers it, so we send that same click programmatically.
    ///
    /// The click target is the top-left corner of the canvas (10pt
    /// inset from each edge), well clear of the stem pill and status
    /// pill regions. The canvas's mouseDown handler doesn't act on
    /// single clicks (only double-clicks trigger zoom toggle), so
    /// this is invisible to the user.
    private func dismissCleanly() {
        queryFocused = false
        onDismiss()
        DispatchQueue.main.async {
            Self.simulateCanvasClick()
        }
    }

    private static func simulateCanvasClick() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isMainWindow }),
              let canvas = ContentView.findCanvasNSView(in: window.contentView) else {
            return
        }
        // Convert canvas-local (10, 10) to window coords. AppKit
        // window coords have origin bottom-left.
        let cornerInCanvas = NSPoint(x: 10, y: 10)
        let pointInWindow = canvas.convert(cornerInCanvas, to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: pointInWindow,
                modifierFlags: [], timestamp: now,
                windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
            ),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: pointInWindow,
                modifierFlags: [], timestamp: now + 0.01,
                windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0.0
            )
        else { return }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// Resolve the query into a sortedEntries index, in this order:
    /// 1. Numeric query in [1, count] → that 1-based index.
    /// 2. Exact stem match → that entry's sortedEntries index.
    /// 3. First substring suggestion → its index.
    private func resolveTargetIndex() -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let shoot = state.shoot, !trimmed.isEmpty else { return nil }
        if let n = Int(trimmed), n >= 1, n <= shoot.count {
            return n - 1
        }
        if let exactIdx = shoot.entries.firstIndex(where: { $0.stem == trimmed }) {
            return exactIdx
        }
        if let firstMatch = suggestions.first,
           let idx = shoot.entries.firstIndex(where: { $0.stem == firstMatch }) {
            return idx
        }
        return nil
    }

    /// Greatest common alphabetic prefix across every stem in the
    /// shoot. `["DSC04177", "DSC04178"]` → `"DSC0"`. Empty when the
    /// shoot has zero or one entries (nothing to common up) or when
    /// stems have no shared prefix.
    private func commonStemPrefix() -> String {
        let stems = allStems
        guard stems.count >= 2, var prefix = stems.first else { return "" }
        for s in stems.dropFirst() {
            while !s.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }
}
