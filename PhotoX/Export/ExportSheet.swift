import SwiftUI
import AppKit

/// Modal popup that configures and triggers exports. Dismissable while a
/// run is in progress; the toolbar pill keeps reporting status.
struct ExportSheet: View {
    @Bindable var state: ViewerState
    @Binding var isPresented: Bool
    @State private var settings = ExportSettings.shared
    @State private var runner = ExportRunner.shared
    @State private var dropTarget: UUID? = nil

    /// Explicit focus on the project-name field. Without this the sheet
    /// inherits focus from the (now-unfocused) canvas and the TextField
    /// silently doesn't receive key input — typing 't' would fall through
    /// to ContentView's filmstrip-toggle shortcut.
    @FocusState private var projectNameFocused: Bool

    private var projectNameBinding: Binding<String> {
        Binding(
            get: { settings.projectName },
            set: { settings.setProjectName($0) }
        )
    }

    private var canRun: Bool {
        settings.isValidForExport && !settings.destinations.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(16) }
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .onAppear { projectNameFocused = true }
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.doc.on.clipboard")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export").font(.title3.bold())
                if !canRun {
                    Text("Set a project name and add at least one destination to enable export.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Files land at <destination>/\(settings.projectName.trimmingCharacters(in: .whitespacesAndNewlines))/")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (export continues in background if running)")
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let batch = runner.batchProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProgressView(value: batch.percent)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 320)
                        Text("\(Int(batch.percent * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let eta = batch.eta {
                            Text("ETA \(formattedDuration(eta))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(batch.filesDone) / \(batch.filesTotal) files across all destinations")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if runner.isRunning {
                Button("Cancel all") { runner.cancelAll() }
            }
            Button("Close") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button {
                runExportAll()
            } label: {
                Label("Export all", systemImage: "arrow.up.doc.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun || runner.isRunning)
        }
        .padding(16)
    }

    // MARK: content

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            projectSection
            destinationsSection
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Project name")
                .font(.caption.smallCaps()).foregroundStyle(.secondary)
            TextField("Required to export", text: projectNameBinding)
                .textFieldStyle(.roundedBorder)
                .focused($projectNameFocused)
                .disabled(runner.isRunning)
            Toggle(isOn: $settings.readOnceWriteMany) {
                Label("Read each file once, write to all destinations",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Saves I/O on slow source media (SD cards) when running 'Export all'. Has no effect when running destinations individually.")
            .disabled(runner.isRunning)
        }
    }

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Destinations")
                    .font(.caption.smallCaps()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    pickDestinationFolder()
                } label: {
                    Label("Add destination", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(runner.isRunning)
            }

            if settings.destinations.isEmpty {
                Text("No destinations configured. Add one to start.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(settings.destinations) { dest in
                        ExportDestinationRow(
                            destination: dest,
                            runnerState: runner.perDestination[dest.id] ?? .idle,
                            completedAt: runner.perDestinationCompletedAt[dest.id],
                            canRun: canRun,
                            isAnotherRunning: runner.isRunning,
                            onRunOne: { runExportOne(dest) },
                            onCancel: { runner.cancel(dest.id) },
                            onRemove: { settings.remove(id: dest.id) },
                            onChange: { mutate in settings.update(id: dest.id, mutate) }
                        )
                        .overlay(alignment: .top) {
                            if dropTarget == dest.id {
                                Capsule().fill(Color.accentColor)
                                    .frame(height: 3)
                                    .padding(.horizontal, -2)
                                    .offset(y: -3)
                                    .transition(.opacity)
                            }
                        }
                        .dropDestination(
                            for: String.self,
                            action: { ids, _ in
                                guard let src = ids.first,
                                      let sourceID = UUID(uuidString: src),
                                      sourceID != dest.id else { return false }
                                settings.move(sourceID, before: dest.id)
                                dropTarget = nil
                                return true
                            },
                            isTargeted: { isTargeted in
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    if isTargeted { dropTarget = dest.id }
                                    else if dropTarget == dest.id { dropTarget = nil }
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: actions

    private func pickDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Let the user create a new folder inline (the picker grows a
        // "New Folder" button in its toolbar). Without this, they'd have
        // to bounce out to Finder, create the folder, then come back.
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select or create a destination folder for exports"
        if panel.runModal() == .OK, let url = panel.url {
            settings.add(path: url.path)
        }
    }

    private func runExportAll() {
        guard canRun, let shoot = state.shoot else { return }
        let needsConfirm = settings.destinations.contains(where: \.removeOrphans)
        if needsConfirm, !confirmOrphanRemoval(forSingle: nil) { return }
        runner.startAll(
            pairs: shoot.pairs,
            pairXMPs: state.pairXMPs,
            projectName: settings.projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            destinations: settings.destinations,
            sharedRead: settings.readOnceWriteMany
        )
    }

    private func runExportOne(_ dest: ExportSettings.Destination) {
        guard canRun, let shoot = state.shoot else { return }
        if dest.removeOrphans, !confirmOrphanRemoval(forSingle: dest) { return }
        runner.startOne(
            dest.id,
            pairs: shoot.pairs,
            pairXMPs: state.pairXMPs,
            projectName: settings.projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            destination: dest
        )
    }

    /// Confirm before destructive orphan removal. `forSingle == nil` means
    /// the user pressed Export all and one or more destinations have the
    /// flag enabled.
    private func confirmOrphanRemoval(forSingle: ExportSettings.Destination?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove orphaned files?"
        if let dest = forSingle {
            alert.informativeText = "Destination \(dest.path) has 'Remove orphans' enabled. Any files at the destination whose stem isn't in the filtered selection will be deleted after the copy phase. This cannot be undone."
        } else {
            let count = settings.destinations.filter(\.removeOrphans).count
            alert.informativeText = "\(count) of your destinations have 'Remove orphans' enabled. Any files at those destinations whose stem isn't in the filtered selection will be deleted after the copy phase. This cannot be undone."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let goBtn = alert.addButton(withTitle: "Export and remove")
        goBtn.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Human-friendly "ago" label. Under a minute → "<1m ago"; under an hour
/// → "Nm ago"; an hour or more → "Nh ago".
func agoString(from date: Date, now: Date = Date()) -> String {
    let elapsed = max(0, now.timeIntervalSince(date))
    let minutes = Int(elapsed / 60)
    if minutes < 1 { return "<1m ago" }
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    return "\(hours)h ago"
}

/// Format an interval like "1m 20s" or "5s".
@MainActor
func formattedDuration(_ seconds: TimeInterval) -> String {
    let total = max(1, Int(seconds.rounded()))
    if total < 60 { return "\(total)s" }
    let m = total / 60, s = total % 60
    if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
    let h = m / 60, mm = m % 60
    return "\(h)h \(mm)m"
}
