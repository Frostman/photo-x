import SwiftUI
import AppKit

/// Inline pane that configures and triggers exports. Rendered as the
/// `.export` branch of `ContentView`'s `WorkspaceMode` switch — the
/// segmented toolbar picker (or ⌘3) flips between this and the
/// viewer. Per-shoot working state lives on `state.exportConfig`;
/// the per-window runner on `state.exportRunner`. The global
/// preset library (`ExportPresetsLibrary.shared`) seeds the working
/// state when the user applies a preset and is the global save
/// target for "Save back to <preset>" / "Save as new" actions.
struct ExportPaneView: View {
    @Bindable var state: ViewerState
    /// Workspace-wide focus binding owned by `ContentView`.
    /// Binding the TextField via this shared state (instead of
    /// a private @FocusState) is what makes the Export → View
    /// transition reliably re-engage canvas key handling.
    var focus: FocusState<WorkspaceFocus?>.Binding
    @State private var library = ExportPresetsLibrary.shared
    @State private var dropTarget: UUID? = nil
    @State private var showSaveAsPresetSheet = false
    @State private var pendingPresetName = ""
    @State private var showOverwritePresetSheet = false
    @State private var pendingOverwriteID: UUID? = nil
    @State private var showManagePresetsSheet = false

    private var runner: ExportRunner { state.exportRunner }

    var body: some View {
        VStack(spacing: 0) {
            if state.exportConfig != nil {
                fullPane
            } else {
                emptyState
            }
        }
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.up.doc.on.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Open a shoot to start an export")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Each shoot remembers its own project name, destinations, and preset.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Full pane (shoot is loaded)

    @ViewBuilder
    private var fullPane: some View {
        if let config = state.exportConfig {
            VStack(spacing: 0) {
                header(config: config)
                Divider()
                ScrollView { content(config: config).padding(16) }
                Divider()
                footer(config: config)
            }
            .sheet(isPresented: $showSaveAsPresetSheet) {
                SaveAsPresetSheet(
                    name: $pendingPresetName,
                    onCancel: { showSaveAsPresetSheet = false },
                    onSave: { newName in
                        _ = config.saveAsNewPreset(name: newName)
                        showSaveAsPresetSheet = false
                        pendingPresetName = ""
                    }
                )
            }
            .sheet(isPresented: $showOverwritePresetSheet) {
                OverwritePresetSheet(
                    library: library,
                    selectedID: $pendingOverwriteID,
                    excludingID: config.sourcePresetID,
                    onCancel: { showOverwritePresetSheet = false },
                    onConfirm: { id in
                        config.saveOverwriting(presetID: id)
                        showOverwritePresetSheet = false
                        pendingOverwriteID = nil
                    }
                )
            }
            .sheet(isPresented: $showManagePresetsSheet) {
                ManagePresetsSheet(library: library,
                                   onClose: { showManagePresetsSheet = false })
            }
        }
    }

    private func header(config: ShootExportConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.doc.on.clipboard")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export").font(.title3.bold())
                if !canRun(config) {
                    Text("Set a project name and add at least one destination to enable export.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("export.header.summary")
                } else {
                    Text("Files land at <destination>/\(config.trimmedProjectName)/")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("export.header.summary")
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func footer(config: ShootExportConfig) -> some View {
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
                runExportAll(config: config)
            } label: {
                Label("Export all", systemImage: "arrow.up.doc.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun(config) || runner.isRunning)
            .accessibilityIdentifier("export.runAll")
        }
        .padding(16)
        .helpAnchor(.exportRun)
    }

    // MARK: - Content sections

    @ViewBuilder
    private func content(config: ShootExportConfig) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            presetSection(config: config)
            projectSection(config: config)
            sourceSection
            destinationsSection(config: config)
        }
    }

    private func presetSection(config: ShootExportConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preset")
                    .font(.caption.smallCaps()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showManagePresetsSheet = true
                } label: {
                    Label("Manage presets…", systemImage: "slider.horizontal.3")
                }
                .controlSize(.small)
                .accessibilityIdentifier("export.managePresets")
                .helpAnchor(.exportManagePresets)
            }
            HStack(spacing: 8) {
                presetPicker(config: config)
                presetActionsMenu(config: config)
            }
            presetProvenanceLine(config: config)
        }
    }

    private func presetPicker(config: ShootExportConfig) -> some View {
        Menu {
            Button("No preset") { config.clearPreset() }
            if !library.presets.isEmpty {
                Divider()
                ForEach(library.presets) { preset in
                    Button {
                        config.applyPreset(preset)
                    } label: {
                        if preset.id == config.sourcePresetID {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tray.full")
                Text(presetPickerLabel(config: config))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .controlSize(.regular)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("export.presetPicker")
        .accessibilityLabel(presetPickerLabel(config: config))
        .helpAnchor(.exportPresetPicker)
    }

    private func presetPickerLabel(config: ShootExportConfig) -> String {
        if config.sourcePresetID == nil { return "No preset" }
        return config.sourcePresetNameCached ?? "Preset"
    }

    @ViewBuilder
    private func presetActionsMenu(config: ShootExportConfig) -> some View {
        Menu {
            if config.sourcePresetID != nil, config.sourcePresetExists {
                Button("Save changes to \"\(config.sourcePresetNameCached ?? "preset")\"") {
                    config.saveBackToSourcePreset()
                }
                .disabled(!config.isModifiedFromPreset)
                Button("Reset to \"\(config.sourcePresetNameCached ?? "preset")\"") {
                    resetToPreset(config: config)
                }
                .disabled(!config.isModifiedFromPreset && !config.presetChangedSinceApply)
            }
            Button("Save as new preset…") {
                pendingPresetName = config.sourcePresetNameCached ?? ""
                showSaveAsPresetSheet = true
            }
            Button("Save to existing preset…") {
                pendingOverwriteID = nil
                showOverwritePresetSheet = true
            }
            .disabled(library.presets.isEmpty
                || (library.presets.count == 1 && library.presets[0].id == config.sourcePresetID))
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.regular)
        .fixedSize()
        .accessibilityIdentifier("export.presetActions")
    }

    /// Text shown by the provenance badge for the current state. Kept
    /// as a single string per state so the `export.presetProvenance.badge`
    /// AX label is the authoritative testing surface. Tests assert on
    /// the prefix ("Modified from", "Up to date with", "No preset
    /// applied"); the suffix is the preset name when applicable.
    private func provenanceBadgeText(config: ShootExportConfig) -> String {
        if config.sourcePresetID == nil {
            return "No preset applied"
        }
        let name = config.sourcePresetNameCached ?? "?"
        if config.isModifiedFromPreset {
            return "Modified from \"\(name)\""
        }
        return "Up to date with \"\(name)\""
    }

    @ViewBuilder
    private func presetProvenanceLine(config: ShootExportConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if config.presetChangedSinceApply {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Preset \"\(config.sourcePresetNameCached ?? "?")\" was updated since you applied it.")
                        .font(.caption)
                    Button("Reload from preset") {
                        config.reloadFromSourcePreset()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("export.presetProvenance.reloadFromPreset")
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("export.presetProvenance.staleBanner")
            }
            badgeLabel(config: config)
        }
    }

    /// The provenance chip — always rendered (even with no preset
    /// applied) so the `export.presetProvenance.badge` identifier is
    /// reliably present; its label content varies by state.
    ///
    /// `.accessibilityElement(children: .ignore)` makes the wrapper
    /// the AX leaf so `.accessibilityLabel(text)` actually surfaces
    /// — without it, SwiftUI keeps the inner `Label`/`Text` as the
    /// AX descendants and XCUITest reads an empty label off the
    /// wrapper.
    @ViewBuilder
    private func badgeLabel(config: ShootExportConfig) -> some View {
        let text = provenanceBadgeText(config: config)
        Group {
            if config.sourcePresetID == nil {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if config.isModifiedFromPreset {
                Label(text, systemImage: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label(text, systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("export.presetProvenance.badge")
        .accessibilityLabel(text)
    }

    private func projectSection(config: ShootExportConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Project name")
                .font(.caption.smallCaps()).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Required to export", text: Binding(
                    get: { config.projectName },
                    set: { config.setProjectNameFromUser($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .exportProjectName)
                .disabled(runner.isRunning)
                .accessibilityIdentifier("export.projectName")
                if config.projectNameIsUserOverride {
                    Button {
                        let dates = state.entryExif.values.compactMap(\.dateTime)
                        config.resetProjectNameToAuto(dates: dates)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Re-derive from photo dates")
                    .accessibilityIdentifier("export.projectName.resetToAuto")
                }
            }
            Toggle(isOn: Binding(
                get: { config.readOnceWriteMany },
                set: { config.setReadOnceWriteMany($0) }
            )) {
                Label("Read each file once, write to all destinations",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Saves I/O on slow source media (SD cards) when running 'Export all'. Has no effect when running destinations individually.")
            .disabled(runner.isRunning)
            .accessibilityIdentifier("export.readOnceWriteMany")
        }
        .helpAnchor(.exportProject)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.caption.smallCaps()).foregroundStyle(.secondary)
            ExportSourceCard(
                sourceURL: state.shoot?.folderURL,
                runner: runner
            )
        }
    }

    private func destinationsSection(config: ShootExportConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Destinations")
                    .font(.caption.smallCaps()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    pickDestinationFolder(config: config)
                } label: {
                    Label("Add destination", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(runner.isRunning)
                .helpAnchor(.exportDestinations)
                .accessibilityIdentifier("export.addDestination")
            }

            if config.destinations.isEmpty {
                Text("No destinations configured. Apply a preset or add one to start.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(config.destinations.enumerated()), id: \.element.id) { idx, dest in
                        ExportDestinationRow(
                            rowIndex: idx,
                            destination: dest,
                            runnerState: runner.perDestination[dest.id] ?? .idle,
                            completedAt: runner.perDestinationCompletedAt[dest.id],
                            canRun: canRun(config),
                            isAnotherRunning: runner.isRunning,
                            planningProgress: runner.planningProgress?.destinations[dest.id],
                            onRunOne: { runExportOne(dest, config: config) },
                            onCancel: { runner.cancel(dest.id) },
                            onRemove: { config.removeDestination(id: dest.id) },
                            onChange: { mutate in config.updateDestination(id: dest.id, mutate) }
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
                                config.moveDestination(sourceID, before: dest.id)
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
                        .conditional(dest.id == config.destinations.first?.id) { row in
                            row.helpAnchor(.exportDestinationCard)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func canRun(_ config: ShootExportConfig) -> Bool {
        config.isValidForExport && !config.destinations.isEmpty
    }

    // MARK: - Actions

    private func pickDestinationFolder(config: ShootExportConfig) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select or create a destination folder for exports"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let shootURL = state.shoot?.folderURL,
           let conflict = ExportPathGeometry.sourceConflict(
            destPath: url.path, sourcePath: shootURL.path) {
            presentSourceConflict(conflict, attemptedPath: url.path,
                                  sourcePath: shootURL.path)
            return
        }
        let result = config.addDestination(path: url.path)
        if case .ok = result { return }
        presentAddRejection(result, attemptedPath: url.path)
    }

    private func presentSourceConflict(_ conflict: ExportPreset.SourceConflict,
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

    private func presentAddRejection(_ result: ExportPreset.AddResult,
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

    private func runExportAll(config: ShootExportConfig) {
        guard canRun(config), let shoot = state.shoot else { return }
        if !confirmSourceConflictsClean(forSingle: nil, shoot: shoot, config: config) { return }
        let needsConfirm = config.destinations.contains(where: \.removeOrphans)
        if needsConfirm, !confirmOrphanRemoval(forSingle: nil, config: config) { return }
        // Flush any debounced save so the per-shoot config file
        // exists on disk with a current mtime before the export
        // starts. LRU purge keeps shoots by file mtime — a shoot
        // that's actively being exported from must survive even if
        // the user never edited its config in this session.
        config.flushPendingSave()
        runner.startAll(
            entries: shoot.entries,
            entryXMPs: state.entryXMPs,
            projectName: config.trimmedProjectName,
            destinations: config.destinations,
            sharedRead: config.readOnceWriteMany
        )
    }

    private func runExportOne(_ dest: ExportPreset.Destination,
                              config: ShootExportConfig) {
        guard canRun(config), let shoot = state.shoot else { return }
        if !confirmSourceConflictsClean(forSingle: dest, shoot: shoot, config: config) { return }
        if dest.removeOrphans, !confirmOrphanRemoval(forSingle: dest, config: config) { return }
        config.flushPendingSave()
        runner.startOne(
            dest.id,
            entries: shoot.entries,
            entryXMPs: state.entryXMPs,
            projectName: config.trimmedProjectName,
            destination: dest
        )
    }

    private func confirmSourceConflictsClean(
        forSingle: ExportPreset.Destination?,
        shoot: Shoot,
        config: ShootExportConfig
    ) -> Bool {
        let sourcePath = shoot.folderURL.path
        let conflicts: [(ExportPreset.Destination, ExportPreset.SourceConflict)]
        if let dest = forSingle {
            conflicts = ExportPathGeometry.sourceConflict(
                destPath: dest.path, sourcePath: sourcePath
            ).map { [(dest, $0)] } ?? []
        } else {
            conflicts = config.sourceConflicts(againstSource: sourcePath)
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

    private func resetToPreset(config: ShootExportConfig) {
        if config.isModifiedFromPreset {
            let alert = NSAlert()
            let name = config.sourcePresetNameCached ?? "preset"
            alert.messageText = "Reset to preset \"\(name)\"?"
            alert.informativeText = "Local changes to destinations and the read-once-write-many toggle will be discarded and replaced with the preset's current state. This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            let resetBtn = alert.addButton(withTitle: "Reset")
            resetBtn.hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        config.reloadFromSourcePreset()
    }

    private func confirmOrphanRemoval(forSingle: ExportPreset.Destination?,
                                      config: ShootExportConfig) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove orphaned files?"
        if let dest = forSingle {
            alert.informativeText = "Destination \(dest.path) has 'Remove orphans' enabled. Any files at the destination whose stem isn't in the filtered selection will be deleted after the copy phase. This cannot be undone."
        } else {
            let count = config.destinations.filter(\.removeOrphans).count
            alert.informativeText = "\(count) of your destinations have 'Remove orphans' enabled. Any files at those destinations whose stem isn't in the filtered selection will be deleted after the copy phase. This cannot be undone."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let goBtn = alert.addButton(withTitle: "Export and remove")
        goBtn.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// "Save as new preset…" inline sheet — takes a name, calls back.
private struct SaveAsPresetSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as new preset")
                .font(.headline)
            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .accessibilityIdentifier("export.saveAsPreset.name")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("export.saveAsPreset.cancel")
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("export.saveAsPreset.save")
            }
        }
        .padding(16)
    }
}

/// "Save to existing preset…" inline sheet — pick a preset to overwrite.
private struct OverwritePresetSheet: View {
    let library: ExportPresetsLibrary
    @Binding var selectedID: UUID?
    let excludingID: UUID?
    let onCancel: () -> Void
    let onConfirm: (UUID) -> Void

    private var options: [ExportPreset] {
        library.presets.filter { $0.id != excludingID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overwrite existing preset")
                .font(.headline)
            Text("Choose a preset to replace with this shoot's current destinations and settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Preset", selection: $selectedID) {
                Text("Select preset…").tag(UUID?.none)
                ForEach(options) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 320)
            .accessibilityIdentifier("export.overwritePreset.picker")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("export.overwritePreset.cancel")
                Button("Overwrite") {
                    guard let id = selectedID else { return }
                    onConfirm(id)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
                .accessibilityIdentifier("export.overwritePreset.confirm")
            }
        }
        .padding(16)
    }
}

/// Minimal preset-library management: list, rename, delete, and
/// configure the default `readOnceWriteMany` value used when
/// creating new presets.
private struct ManagePresetsSheet: View {
    @Bindable var library: ExportPresetsLibrary
    let onClose: () -> Void
    @State private var renamingID: UUID? = nil
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage presets")
                .font(.headline)
            if library.presets.isEmpty {
                Text("No presets yet. Configure destinations in a shoot and use \"Save as new preset…\" to create one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360, alignment: .leading)
            } else {
                List {
                    ForEach(Array(library.presets.enumerated()), id: \.element.id) { idx, preset in
                        HStack(spacing: 6) {
                            if renamingID == preset.id {
                                TextField("Name", text: $renameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("export.managePresets.row.\(idx).renameField")
                                Button("Save") {
                                    var updated = preset
                                    updated.name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !updated.name.isEmpty {
                                        library.update(updated)
                                    }
                                    renamingID = nil
                                }
                                .controlSize(.small)
                                .accessibilityIdentifier("export.managePresets.row.\(idx).saveRename")
                                Button("Cancel") { renamingID = nil }
                                    .controlSize(.small)
                                    .accessibilityIdentifier("export.managePresets.row.\(idx).cancelRename")
                            } else {
                                Text(preset.name)
                                    .accessibilityIdentifier("export.managePresets.row.\(idx).name")
                                Spacer()
                                Text("\(preset.destinations.count) destination\(preset.destinations.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    renamingID = preset.id
                                    renameDraft = preset.name
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .accessibilityIdentifier("export.managePresets.row.\(idx).rename")
                                Button(role: .destructive) {
                                    confirmAndRemove(preset)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .accessibilityIdentifier("export.managePresets.row.\(idx).delete")
                            }
                        }
                    }
                }
                .frame(width: 420, height: 220)
            }
            Divider()
            Toggle(isOn: Binding(
                get: { library.defaultReadOnceWriteMany },
                set: { library.defaultReadOnceWriteMany = $0 }
            )) {
                Text("New presets default to read-once / write-many")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("export.managePresets.defaultRoWM")
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("export.managePresets.done")
            }
        }
        .padding(16)
    }

    private func confirmAndRemove(_ preset: ExportPreset) {
        let alert = NSAlert()
        alert.messageText = "Delete preset \"\(preset.name)\"?"
        alert.informativeText = "Shoots currently linked to this preset keep their destinations and settings but lose the link. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let delBtn = alert.addButton(withTitle: "Delete")
        delBtn.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn {
            library.remove(id: preset.id)
        }
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
