import Foundation
import Observation

/// Per-shoot working state for the Export feature. Owned by
/// `ViewerState` — one instance per window's currently-open shoot.
///
/// Project name auto-derives from the shoot's EXIF dates until the
/// user edits it; the override flag pins the user's typed value so
/// subsequent EXIF flushes don't overwrite it. Destinations start
/// empty (or populated by the active preset) and edits stay local
/// to the shoot — the user explicitly saves them back to a preset
/// when ready.
@MainActor
@Observable
final class ShootExportConfig {

    let shootPath: String

    /// Folder name (last path component of the shoot URL). Used as
    /// the fallback project name when no EXIF dates are available.
    var folderName: String

    var projectName: String
    var projectNameIsUserOverride: Bool

    var destinations: [ExportPreset.Destination]
    var readOnceWriteMany: Bool

    // Preset provenance — nil until a preset is applied. Survives
    // preset deletion (we cache the name so the badge still reads
    // sensibly) and detects "preset changed since you applied it"
    // by comparing the source preset's current `updatedAt` against
    // the snapshot timestamp taken on apply.
    var sourcePresetID: UUID?
    var sourcePresetNameCached: String?
    var sourcePresetSnapshotDestinations: [ExportPreset.Destination]?
    var sourcePresetSnapshotReadOnceWriteMany: Bool?
    var sourcePresetSnapshotAt: Date?

    private let store: ShootExportConfigStore
    private let library: ExportPresetsLibrary

    /// Pending debounce work-item for the next save. Coalesces rapid
    /// edits (typing in the project name, toggling filters) into
    /// one disk write per ~250 ms.
    private var pendingSaveTask: Task<Void, Never>?

    /// Snapshotted EXIF dates the deriver last ran against — so we
    /// don't reflow the project name when EXIF re-arrives unchanged.
    private var lastDerivedDateCount: Int = 0

    init(shootPath: String,
         folderName: String,
         store: ShootExportConfigStore,
         library: ExportPresetsLibrary) {
        self.shootPath = shootPath
        self.folderName = folderName
        self.store = store
        self.library = library

        if let data = store.load(forShootPath: shootPath) {
            self.projectName = data.projectName
            self.projectNameIsUserOverride = data.projectNameIsUserOverride
            self.destinations = data.destinations
            self.readOnceWriteMany = data.readOnceWriteMany
            self.sourcePresetID = data.sourcePresetID
            self.sourcePresetNameCached = data.sourcePresetNameCached
            self.sourcePresetSnapshotDestinations = data.sourcePresetSnapshotDestinations
            self.sourcePresetSnapshotReadOnceWriteMany = data.sourcePresetSnapshotReadOnceWriteMany
            self.sourcePresetSnapshotAt = data.sourcePresetSnapshotAt
        } else {
            self.projectName = folderName
            self.projectNameIsUserOverride = false
            self.destinations = []
            self.readOnceWriteMany = library.defaultReadOnceWriteMany
            self.sourcePresetID = nil
            self.sourcePresetNameCached = nil
            self.sourcePresetSnapshotDestinations = nil
            self.sourcePresetSnapshotReadOnceWriteMany = nil
            self.sourcePresetSnapshotAt = nil
        }
    }

    // MARK: - Project name

    var trimmedProjectName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValidForExport: Bool {
        !trimmedProjectName.isEmpty
    }

    /// Called by `ViewerState` when EXIF dates are loaded or flushed.
    /// No-op when the user has overridden the project name. Triggers
    /// a debounced persist only if the derived value actually changed.
    func refreshAutoProjectName(dates: [Date]) {
        guard !projectNameIsUserOverride else { return }
        guard dates.count != lastDerivedDateCount else { return }
        lastDerivedDateCount = dates.count
        let derived = ProjectNameDeriver.derive(from: dates, folderName: folderName)
        if derived != projectName {
            projectName = derived
            scheduleSave()
        }
    }

    /// User typed into the project-name field. Pins the value as an
    /// override so EXIF flushes leave it alone.
    func setProjectNameFromUser(_ name: String) {
        projectName = name
        projectNameIsUserOverride = true
        scheduleSave()
    }

    /// Clear the user override and re-derive from the supplied dates.
    /// Bound to the "↻" affordance next to the project-name field.
    func resetProjectNameToAuto(dates: [Date]) {
        projectNameIsUserOverride = false
        lastDerivedDateCount = 0
        refreshAutoProjectName(dates: dates)
        // refreshAutoProjectName only persists when the value changes;
        // explicitly persist here so the override flag flip itself
        // makes it to disk.
        scheduleSave()
    }

    // MARK: - Destinations CRUD

    @discardableResult
    func addDestination(path: String) -> ExportPreset.AddResult {
        let normalized = ExportPathGeometry.normalize(path)
        for existing in destinations {
            let exNorm = ExportPathGeometry.normalize(existing.path)
            if exNorm == normalized { return .duplicate }
            if ExportPathGeometry.isStrictParent(exNorm, of: normalized) {
                return .nestedUnder(existingPath: existing.path)
            }
            if ExportPathGeometry.isStrictParent(normalized, of: exNorm) {
                return .containsExisting(existingPath: existing.path)
            }
        }
        destinations.append(ExportPreset.Destination(path: path))
        scheduleSave()
        return .ok
    }

    func removeDestination(id: UUID) {
        let before = destinations.count
        destinations.removeAll { $0.id == id }
        guard destinations.count != before else { return }
        scheduleSave()
    }

    func updateDestination(id: UUID, _ mutate: (inout ExportPreset.Destination) -> Void) {
        guard let idx = destinations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&destinations[idx])
        scheduleSave()
    }

    /// Reorder by moving `id` to land directly before `targetID`.
    func moveDestination(_ id: UUID, before targetID: UUID) {
        guard let from = destinations.firstIndex(where: { $0.id == id }),
              let to = destinations.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        var next = destinations
        let element = next.remove(at: from)
        let insertAt = from < to ? to - 1 : to
        next.insert(element, at: insertAt)
        destinations = next
        scheduleSave()
    }

    /// Re-validate every destination against the current source folder.
    /// Used at run time — the add-time check ran against whatever shoot
    /// was open then; the source may have changed since.
    func sourceConflicts(againstSource sourcePath: String)
        -> [(destination: ExportPreset.Destination, conflict: ExportPreset.SourceConflict)] {
        destinations.compactMap { dest in
            ExportPathGeometry.sourceConflict(destPath: dest.path, sourcePath: sourcePath)
                .map { (dest, $0) }
        }
    }

    func setReadOnceWriteMany(_ value: Bool) {
        readOnceWriteMany = value
        scheduleSave()
    }

    // MARK: - Preset operations

    /// Diff against the snapshot taken at the time the source preset
    /// was applied. Returns false once a preset has been applied
    /// AND the working state still matches it.
    var isModifiedFromPreset: Bool {
        guard sourcePresetID != nil else { return false }
        if destinations != sourcePresetSnapshotDestinations { return true }
        if readOnceWriteMany != sourcePresetSnapshotReadOnceWriteMany { return true }
        return false
    }

    /// True when the source preset has been updated globally since we
    /// snapshotted it. The UI shows an "amber" banner with a reload
    /// button when this returns true.
    var presetChangedSinceApply: Bool {
        guard let id = sourcePresetID,
              let snapAt = sourcePresetSnapshotAt,
              let current = library.preset(id: id)
        else { return false }
        return current.updatedAt > snapAt
    }

    /// Whether the source preset still exists in the library. Used to
    /// disable "Save to <preset>" and offer "Save as new" instead.
    var sourcePresetExists: Bool {
        guard let id = sourcePresetID else { return false }
        return library.preset(id: id) != nil
    }

    func applyPreset(_ preset: ExportPreset) {
        destinations = preset.destinations
        readOnceWriteMany = preset.readOnceWriteMany
        sourcePresetID = preset.id
        sourcePresetNameCached = preset.name
        sourcePresetSnapshotDestinations = preset.destinations
        sourcePresetSnapshotReadOnceWriteMany = preset.readOnceWriteMany
        sourcePresetSnapshotAt = preset.updatedAt
        scheduleSave()
    }

    /// Clear any preset linkage and zero out destinations. Used by
    /// the "No preset" menu entry.
    func clearPreset() {
        sourcePresetID = nil
        sourcePresetNameCached = nil
        sourcePresetSnapshotDestinations = nil
        sourcePresetSnapshotReadOnceWriteMany = nil
        sourcePresetSnapshotAt = nil
        scheduleSave()
    }

    /// Reload the working state from the current source preset
    /// (after the user accepts the "preset updated" banner).
    func reloadFromSourcePreset() {
        guard let id = sourcePresetID,
              let current = library.preset(id: id) else { return }
        applyPreset(current)
    }

    /// Write the current working state back to the source preset.
    /// Bumps the preset's `updatedAt`; refreshes our snapshot so the
    /// "modified" badge clears immediately.
    func saveBackToSourcePreset() {
        guard let id = sourcePresetID,
              var current = library.preset(id: id) else { return }
        current.name = sourcePresetNameCached ?? current.name
        current.destinations = destinations
        current.readOnceWriteMany = readOnceWriteMany
        library.update(current)
        if let refreshed = library.preset(id: id) {
            sourcePresetSnapshotDestinations = refreshed.destinations
            sourcePresetSnapshotReadOnceWriteMany = refreshed.readOnceWriteMany
            sourcePresetSnapshotAt = refreshed.updatedAt
            sourcePresetNameCached = refreshed.name
        }
        scheduleSave()
    }

    /// Create a new preset from the current working state and adopt
    /// it as the source.
    func saveAsNewPreset(name: String) -> ExportPreset {
        let preset = ExportPreset(name: name,
                                  destinations: destinations,
                                  readOnceWriteMany: readOnceWriteMany)
        library.add(preset)
        if let stored = library.preset(id: preset.id) {
            applyPreset(stored)
            return stored
        }
        applyPreset(preset)
        return preset
    }

    /// Overwrite a different existing preset with the current working
    /// state and adopt it as the new source.
    func saveOverwriting(presetID: UUID) {
        guard var existing = library.preset(id: presetID) else { return }
        existing.destinations = destinations
        existing.readOnceWriteMany = readOnceWriteMany
        library.update(existing)
        if let refreshed = library.preset(id: presetID) {
            applyPreset(refreshed)
        }
    }

    // MARK: - Persistence

    /// Snapshot the current state into a Codable form for the store.
    func snapshot() -> ShootExportConfigData {
        ShootExportConfigData(
            shootPath: shootPath,
            projectName: projectName,
            projectNameIsUserOverride: projectNameIsUserOverride,
            destinations: destinations,
            readOnceWriteMany: readOnceWriteMany,
            sourcePresetID: sourcePresetID,
            sourcePresetNameCached: sourcePresetNameCached,
            sourcePresetSnapshotDestinations: sourcePresetSnapshotDestinations,
            sourcePresetSnapshotReadOnceWriteMany: sourcePresetSnapshotReadOnceWriteMany,
            sourcePresetSnapshotAt: sourcePresetSnapshotAt)
    }

    /// Coalesce rapid mutations into a single disk write. Cancels any
    /// pending save and schedules a new one ~250 ms out.
    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let snap = self.snapshot()
            self.store.save(snap, forShootPath: self.shootPath)
        }
    }

    /// Synchronously flush any pending save. Called by `ViewerState`
    /// when the shoot is about to change so the previous shoot's
    /// final edits land on disk before the next one's state loads.
    func flushPendingSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        store.saveSync(snapshot(), forShootPath: shootPath)
    }
}
