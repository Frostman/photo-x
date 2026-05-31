import SwiftUI

/// Contents of the failures window. Header explains the in-memory
/// state; middle is a scrollable list with one row per stem showing
/// the *intent* the failed write was trying to land (rating, label,
/// or both) as visual badges; bottom has Retry All.
struct FailedWritesView: View {
    @Bindable var state: ViewerState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            failuresList
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
        }
    }

    @ViewBuilder
    private var failuresList: some View {
        if state.failedXMPWrites.isEmpty {
            HStack {
                Spacer()
                Text("All clear — no failed writes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedFailures, id: \.stem) { failure in
                        FailedWriteRow(failure: failure)
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var sortedFailures: [XMPWriteCoordinator.FailedWrite] {
        state.failedXMPWrites.values.sorted { $0.stem < $1.stem }
    }
}

/// One row per failed stem. Shows the stem, badges describing what
/// the failed write was trying to set, timestamp + attempt count,
/// and a one-line truncated error on the secondary line.
private struct FailedWriteRow: View {
    let failure: XMPWriteCoordinator.FailedWrite

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(failure.stem)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                IntentBadgesView(intent: failure.intent)
                Spacer()
                Text(timestamp(failure.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(failure.attempts) attempt\(failure.attempts == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(failure.lastError)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

/// Renders the rating + label portion of a `SidecarIntent` as small
/// visual badges. Skips fields the intent didn't touch (`.none`).
private struct IntentBadgesView: View {
    let intent: SidecarIntent

    var body: some View {
        HStack(spacing: 6) {
            if case .some(let r) = intent.rating {
                ratingBadge(for: r)
            }
            if case .some(let l) = intent.label {
                labelBadge(for: l)
            }
        }
    }

    @ViewBuilder
    private func ratingBadge(for r: Int?) -> some View {
        if let r {
            if r == -1 {
                badge {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("reject")
                }
            } else if r >= 1 && r <= 5 {
                badge {
                    HStack(spacing: 1) {
                        ForEach(0..<r, id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            } else {
                badge {
                    Text("rating \(r)")
                }
            }
        } else {
            badge {
                Image(systemName: "star.slash").foregroundStyle(.secondary)
                Text("rating cleared")
            }
        }
    }

    @ViewBuilder
    private func labelBadge(for l: String?) -> some View {
        if let l, !l.isEmpty {
            badge {
                Circle()
                    .fill(Self.swatch(for: l))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                Text(l)
            }
        } else {
            badge {
                Image(systemName: "tag.slash").foregroundStyle(.secondary)
                Text("label cleared")
            }
        }
    }

    @ViewBuilder
    private func badge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .font(.caption)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    /// Lightroom color palette → SwiftUI Color. Unknown labels fall
    /// back to gray so an out-of-palette name still gets a swatch.
    private static func swatch(for label: String) -> Color {
        switch label.lowercased() {
        case "red":    return .red
        case "yellow": return .yellow
        case "green":  return .green
        case "blue":   return .blue
        case "purple": return .purple
        default:       return .gray
        }
    }
}
