import SwiftUI

/// Contents of the failures window. Top note explains the in-memory
/// state; middle is a read-only TextEditor that lets the user
/// Cmd+A / Cmd+C the list (built on NSTextView under the hood, so
/// system-standard select-all and copy work); bottom has Retry All
/// and Dismiss All.
struct FailedWritesView: View {
    @Bindable var state: ViewerState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            // Read-only TextEditor: `.constant` binding makes it
            // non-editable but keeps NSTextView selection + copy.
            TextEditor(text: .constant(formattedFailures))
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            HStack {
                Spacer()
                Button("Retry All") {
                    state.retryAllFailedXMPWrites()
                    // Don't close — let the user see whether the
                    // retries land. The window auto-closes nothing;
                    // if every retry succeeds the list goes empty
                    // and the next render shows an empty state.
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.failedXMPWrites.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(state.failedXMPWrites.count) write\(state.failedXMPWrites.count == 1 ? "" : "s") failed to save")
                .font(.title3.bold())
            Text("All your decisions are kept in memory. If you quit without resolving, the failed writes will be lost. Click Retry All to attempt again, or fix the underlying issue (e.g., remount the card) and retry.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Tip: Cmd+A then Cmd+C copies the list below.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// One line per failed stem, tab-separated for easy paste into
    /// spreadsheet apps. Sorted by stem so the list is stable
    /// across renders.
    private var formattedFailures: String {
        if state.failedXMPWrites.isEmpty {
            return "All clear — no failed writes."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return state.failedXMPWrites
            .sorted { $0.key < $1.key }
            .map { _, failure in
                let ts = formatter.string(from: failure.timestamp)
                return "\(failure.stem)\t[\(ts)]\t\(failure.kind.description)\t\(failure.attempts)x\t\(failure.lastError)"
            }
            .joined(separator: "\n")
    }
}
