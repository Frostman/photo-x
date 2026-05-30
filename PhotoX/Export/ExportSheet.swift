import SwiftUI
import AppKit

/// Inline pane that configures and triggers exports. Rendered as the
/// `.export` branch of `ContentView`'s `WorkspaceMode` switch — the
/// segmented toolbar picker (or ⌘1 / ⌘2) flips between this and the
/// viewer. Exits leave the underlying singletons untouched, so any
/// running batch keeps going and the toolbar pill keeps reporting.
struct ExportPaneView: View {
    @Bindable var state: ViewerState
    /// Workspace-wide focus binding owned by `ContentView`.
    /// Binding the TextField via this shared state (instead of
    /// a private @FocusState) is what makes the Export → View
    /// transition reliably re-engage canvas key handling —
    /// SwiftUI sees the focus change as one atomic transition
    /// and propagates it into AppKit's responder chain.
    var focus: FocusState<WorkspaceFocus?>.Binding
    @State private var settings = ExportSettings.shared
    @State private var runner = ExportRunner.shared
    @State private var dropTarget: UUID? = nil

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
        // Cap the pane width and let the outer frame centre it
        // horizontally — same spirit as the starter screen's
        // intrinsically-narrow VStack sitting centred in the
        // canvas's full-width container. Wide windows otherwise
        // make TextField + destination rows stretch awkwardly.
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Focus is driven by ContentView's mode-change handler
        // (sets `focus = .exportProjectName`) — no `onAppear`
        // trick needed here.
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
            Button {
                runExportAll()
            } label: {
                Label("Export all", systemImage: "arrow.up.doc.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun || runner.isRunning)
        }
        .padding(16)
        // Anchored on the whole footer (rather than the Export-all
        // button) so the .top callout centres above the window
        // instead of above the right-edge button — the latter
        // overflows the window because Export mode has no canvas
        // anchor for the overlay's clamp logic to fall back on.
        .helpAnchor(.exportRun)
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
                .focused(focus, equals: .exportProjectName)
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
        .helpAnchor(.exportProject)
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
                .helpAnchor(.exportDestinations)
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
                        // Only the first card publishes the help
                        // anchor — one callout per kind of card is
                        // enough, and we want it absent entirely
                        // when there are no destinations.
                        .conditional(dest.id == settings.destinations.first?.id) { row in
                            row.helpAnchor(.exportDestinationCard)
                        }
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Refuse anything that conflicts with the source shoot
        // folder — same path, nested under, or containing it.
        // Copying back into the originals violates the project-
        // wide "never mutate originals" rule; orphan-prune at a
        // destination that wraps the source could wipe real files.
        if let shootURL = state.shoot?.folderURL,
           let conflict = ExportSettings.sourceConflict(
            destPath: url.path, sourcePath: shootURL.path) {
            presentSourceConflict(conflict, attemptedPath: url.path,
                                  sourcePath: shootURL.path)
            return
        }
        let result = settings.add(path: url.path)
        if case .ok = result { return }
        presentAddRejection(result, attemptedPath: url.path)
    }

    /// User-facing copy for the three SourceConflict cases.
    private func presentSourceConflict(_ conflict: ExportSettings.SourceConflict,
                                        attemptedPath: String,
                                        sourcePath: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch conflict {
        case .isSource:
            alert.messageText = "Can't export back into the source shoot folder"
            alert.informativeText = "\(attemptedPath) is the folder you opened. Pick a different folder."
        case .insideSource:
            alert.messageText = "Destination is inside the source shoot folder"
            alert.informativeText = "\(attemptedPath) lives inside the shoot folder \(sourcePath). Pick a folder OUTSIDE the source so PhotoX never writes back into the originals."
        case .containsSource:
            alert.messageText = "Destination contains the source shoot folder"
            alert.informativeText = "\(attemptedPath) contains the shoot folder \(sourcePath). If you turned on orphan removal at this destination, PhotoX could delete originals. Pick a folder that doesn't contain the source."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Modal NSAlert that explains why the picked folder was refused.
    /// Three rejection reasons are all variations on "destinations would
    /// stomp on each other if both ran" — see `ExportSettings.AddResult`.
    private func presentAddRejection(_ result: ExportSettings.AddResult,
                                     attemptedPath: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch result {
        case .ok:
            return
        case .duplicate:
            alert.messageText = "Destination already added"
            alert.informativeText = "\(attemptedPath) is already in the destinations list."
        case .nestedUnder(let parent):
            alert.messageText = "Destination is inside another destination"
            alert.informativeText = "\(attemptedPath) is inside \(parent). Choose a folder that's not within any existing destination."
        case .containsExisting(let child):
            alert.messageText = "Destination contains another destination"
            alert.informativeText = "\(attemptedPath) contains \(child). Choose a folder that doesn't enclose an existing destination."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func runExportAll() {
        guard canRun, let shoot = state.shoot else { return }
        // Re-validate against the source folder on run too — a
        // destination could've been added against a different shoot
        // and now collides with the currently-open one.
        if !confirmSourceConflictsClean(forSingle: nil, shoot: shoot) { return }
        let needsConfirm = settings.destinations.contains(where: \.removeOrphans)
        if needsConfirm, !confirmOrphanRemoval(forSingle: nil) { return }
        if !confirmDestinationNotEmpty(forSingle: nil) { return }
        runner.startAll(
            entries: shoot.entries,
            entryXMPs: state.entryXMPs,
            projectName: settings.projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            destinations: settings.destinations,
            sharedRead: settings.readOnceWriteMany
        )
    }

    private func runExportOne(_ dest: ExportSettings.Destination) {
        guard canRun, let shoot = state.shoot else { return }
        if !confirmSourceConflictsClean(forSingle: dest, shoot: shoot) { return }
        if dest.removeOrphans, !confirmOrphanRemoval(forSingle: dest) { return }
        if !confirmDestinationNotEmpty(forSingle: dest) { return }
        runner.startOne(
            dest.id,
            entries: shoot.entries,
            entryXMPs: state.entryXMPs,
            projectName: settings.projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            destination: dest
        )
    }

    /// Returns true when the destination(s) about to run don't
    /// conflict with the source shoot folder, false (after presenting
    /// an alert) otherwise. `forSingle` scopes the check to one
    /// destination row; nil checks every destination.
    private func confirmSourceConflictsClean(
        forSingle: ExportSettings.Destination?,
        shoot: Shoot
    ) -> Bool {
        let sourcePath = shoot.folderURL.path
        let conflicts: [(ExportSettings.Destination, ExportSettings.SourceConflict)]
        if let dest = forSingle {
            conflicts = ExportSettings.sourceConflict(
                destPath: dest.path, sourcePath: sourcePath
            ).map { [(dest, $0)] } ?? []
        } else {
            conflicts = settings.sourceConflicts(againstSource: sourcePath)
        }
        guard !conflicts.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if conflicts.count == 1, let (dest, conflict) = conflicts.first {
            switch conflict {
            case .isSource:
                alert.messageText = "Destination is the source shoot folder"
                alert.informativeText = "\(dest.path) is the same folder you're culling. Remove or change this destination to run the export."
            case .insideSource:
                alert.messageText = "Destination is inside the source shoot folder"
                alert.informativeText = "\(dest.path) lives inside the shoot folder \(sourcePath). Exporting would write back into the originals. Remove or move this destination."
            case .containsSource:
                alert.messageText = "Destination contains the source shoot folder"
                alert.informativeText = "\(dest.path) contains the shoot folder \(sourcePath). Orphan removal at this destination could delete real originals. Remove or move this destination."
            }
        } else {
            alert.messageText = "Some destinations conflict with the source folder"
            alert.informativeText = conflicts.map { dest, c in
                let label: String
                switch c {
                case .isSource:       label = "same as source"
                case .insideSource:   label = "inside source"
                case .containsSource: label = "contains source"
                }
                return "• \(dest.path) — \(label)"
            }.joined(separator: "\n") + "\n\nRemove or move these destinations to run the export."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
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

    /// In-scope destinations whose `<dest>/<projectName>/` subfolder
    /// already contains at least one non-hidden item. One
    /// non-recursive `contentsOfDirectory` per destination — cheap
    /// on local disks, acceptable on SD cards.
    private func nonEmptyProjectDestinations(
        forSingle: ExportSettings.Destination?
    ) -> [(ExportSettings.Destination, Int)] {
        let project = settings.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return [] }
        let scope = forSingle.map { [$0] } ?? settings.destinations
        let fm = FileManager.default
        return scope.compactMap { dest in
            let subURL = URL(fileURLWithPath: dest.path)
                .appendingPathComponent(project)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subURL.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            let items = (try? fm.contentsOfDirectory(
                at: subURL, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            return items.isEmpty ? nil : (dest, items.count)
        }
    }

    /// Confirm before writing into a project subfolder that already
    /// has content — catches the easy mistake of starting a second
    /// export with the same project name. `forSingle == nil` runs
    /// the combined Export-all alert. Silenced entirely when
    /// `SettingsKey.skipDestinationNotEmptyConfirm` is true.
    private func confirmDestinationNotEmpty(
        forSingle: ExportSettings.Destination?
    ) -> Bool {
        if AppDefaults.shared.bool(forKey: SettingsKey.skipDestinationNotEmptyConfirm) {
            return true
        }
        let hits = nonEmptyProjectDestinations(forSingle: forSingle)
        guard !hits.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if hits.count == 1, let (dest, count) = hits.first {
            let project = settings.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            alert.messageText = "Destination already contains files"
            alert.informativeText = "\(dest.path)/\(project)/ already has \(count) item\(count == 1 ? "" : "s"). Continuing may overwrite or append depending on this destination's overwrite policy. (Disable this confirmation in Settings → Workflow.)"
        } else {
            alert.messageText = "Some destinations already contain files"
            alert.informativeText = hits.map { dest, count in
                "• \(dest.path) — \(count) item\(count == 1 ? "" : "s")"
            }.joined(separator: "\n") + "\n\nContinuing may overwrite or append depending on each destination's overwrite policy. (Disable this confirmation in Settings → Workflow.)"
        }
        alert.addButton(withTitle: "Cancel")
        let goBtn = alert.addButton(withTitle: "Export anyway")
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
