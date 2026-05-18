import SwiftUI

/// One row in the Export sheet's destinations list. Caller owns the
/// underlying `ExportSettings.Destination`; mutations come back via the
/// `onChange` callback so this view stays pure.
struct ExportDestinationRow: View {
    let destination: ExportSettings.Destination
    let runnerState: ExportRunner.DestinationState
    let canRun: Bool
    let isAnotherRunning: Bool
    let onRunOne: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onChange: ((inout ExportSettings.Destination) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            filterRow
            secondRow
            statusRow
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var topRow: some View {
        HStack(spacing: 6) {
            dragHandle
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text((destination.path as NSString).abbreviatingWithTildeInPath)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(destination.path)
            Spacer()
            runButton
            removeButton
        }
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 20)
            .contentShape(Rectangle())
            .help("Drag to rearrange")
            .draggable(destination.id.uuidString) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text((destination.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced())
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
    }

    @ViewBuilder
    private var runButton: some View {
        if isThisRunning {
            Button {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "stop.circle")
            }
            .controlSize(.small)
            .help("Cancel this destination's run")
        } else {
            Button {
                onRunOne()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .controlSize(.small)
            .disabled(!canRun || isAnotherRunning)
            .help(canRun
                  ? "Export to this destination only"
                  : "Set a project name first")
        }
    }

    private var removeButton: some View {
        Button {
            onRemove()
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove this destination")
        .disabled(isThisRunning || isAnotherRunning)
    }

    // MARK: filter + flags row

    private var filterRow: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { stars in
                    Toggle(isOn: starBinding(stars)) {
                        HStack(spacing: 1) {
                            Image(systemName: "star.fill")
                            Text("\(stars)").font(.caption2.monospacedDigit().bold())
                        }
                    }
                    .help("Include \(stars)-star pairs")
                }
            }
            Toggle(isOn: boolBinding(\.showRejected)) {
                Image(systemName: "xmark.circle.fill")
            }
            .help("Include rejected pairs")

            Toggle(isOn: boolBinding(\.showUnrated)) {
                Image(systemName: "circle")
            }
            .help("Include unrated pairs")

            Divider().frame(height: 16)

            Toggle(isOn: boolBinding(\.includeARW)) {
                Text("ARW").font(.caption2.bold())
            }
            .help("Copy .ARW files")
            Toggle(isOn: boolBinding(\.includeHIF)) {
                Text("HIF").font(.caption2.bold())
            }
            .help("Copy .HIF files")
            Toggle(isOn: boolBinding(\.includeXMP)) {
                Text("XMP").font(.caption2.bold())
            }
            .help("Copy .xmp sidecars")
            Spacer()
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .disabled(isThisRunning)
    }

    private var secondRow: some View {
        HStack(spacing: 12) {
            Picker(selection: overwriteBinding) {
                ForEach(ExportSettings.OverwritePolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            } label: {
                Label("Overwrite", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .pickerStyle(.menu)
            .fixedSize()
            .help(destination.overwrite.helpText)

            Toggle(isOn: boolBinding(\.removeOrphans)) {
                Label("Remove orphans", systemImage: destination.removeOrphans
                      ? "trash.fill" : "trash")
                    .foregroundStyle(destination.removeOrphans ? Color.orange : Color.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("After copying, delete files at the destination whose stem isn't in the filtered selection. Destructive — confirmation required.")

            Spacer()
        }
        .disabled(isThisRunning)
    }

    // MARK: status

    @ViewBuilder
    private var statusRow: some View {
        switch runnerState {
        case .idle:
            Text("Idle").font(.caption).foregroundStyle(.secondary)
        case .queued:
            Text("Queued…").font(.caption).foregroundStyle(.secondary)
        case .running(let p):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ProgressView(value: p.percent)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text("\(Int(p.percent * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let eta = p.eta {
                        Text("ETA \(formattedDuration(eta))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let name = p.currentFilename {
                        Text(name)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                Text("\(p.copied) copied · \(p.skipped) skipped · \(p.total) total")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .done(let s):
            Label(
                "Done · \(s.copied) copied · \(s.skipped) skipped"
                + (s.deleted > 0 ? " · \(s.deleted) deleted" : "")
                + (s.errors.isEmpty ? "" : " · \(s.errors.count) errors"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(s.errors.isEmpty ? Color.green : Color.orange)
        case .cancelled(let s):
            Label(
                "Cancelled · \(s.copied) copied · \(s.skipped) skipped",
                systemImage: "stop.circle"
            )
            .font(.caption).foregroundStyle(.secondary)
        case .failed(let message, _):
            Label("Failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: bindings

    private var isThisRunning: Bool {
        if case .running = runnerState { return true }
        if case .queued = runnerState { return true }
        return false
    }

    private func starBinding(_ stars: Int) -> Binding<Bool> {
        Binding(
            get: { destination.showStars.contains(stars) },
            set: { on in
                onChange { dest in
                    if on { dest.showStars.insert(stars) }
                    else { dest.showStars.remove(stars) }
                }
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<ExportSettings.Destination, Bool>) -> Binding<Bool> {
        Binding(
            get: { destination[keyPath: keyPath] },
            set: { v in onChange { $0[keyPath: keyPath] = v } }
        )
    }

    private var overwriteBinding: Binding<ExportSettings.OverwritePolicy> {
        Binding(
            get: { destination.overwrite },
            set: { v in onChange { $0.overwrite = v } }
        )
    }
}
