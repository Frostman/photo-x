import Foundation
import Observation

/// Global library of named destination presets. Persisted as JSON in
/// the app's UserDefaults (`export.presets`). One process-wide instance
/// so every window's Export pane and Manage Presets sheet see the
/// same list — but unlike the old `ExportSettings.shared`, the
/// *applied* destinations live per-shoot in `ShootExportConfig`, so
/// editing a shoot's working copy doesn't leak to other windows.
@MainActor
@Observable
final class ExportPresetsLibrary {
    static let shared = ExportPresetsLibrary()

    private(set) var presets: [ExportPreset] = []

    /// Default `readOnceWriteMany` value for newly created presets.
    /// User-tunable in the Manage Presets sheet; persisted via
    /// UserDefaults (`export.defaultReadOnceWriteMany`).
    var defaultReadOnceWriteMany: Bool {
        didSet { defaults.set(defaultReadOnceWriteMany, forKey: Self.defaultROWMKey) }
    }

    private let defaults: UserDefaults

    private static let presetsKey  = "export.presets"
    private static let defaultROWMKey = "export.defaultReadOnceWriteMany"

    // Legacy singleton keys (pre-rework). Migrated once on first launch
    // after upgrade, then deleted.
    private static let legacyDestinationsKey = "export.destinations"
    private static let legacyProjectNameKey  = "export.projectName"
    private static let legacyROWMKey         = "export.readOnceWriteMany"

    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
        // Seed defaultROWM first — migration may need to read or
        // write it.
        if let stored = defaults.object(forKey: Self.defaultROWMKey) as? Bool {
            self.defaultReadOnceWriteMany = stored
        } else {
            self.defaultReadOnceWriteMany = true
        }
        loadOrMigrate()
    }

    // MARK: - CRUD

    func add(_ preset: ExportPreset) {
        var p = preset
        p.updatedAt = Date()
        presets.append(p)
        persist()
    }

    /// Replace an existing preset, bumping `updatedAt` to "now" so
    /// shoots holding an older snapshot can detect the change.
    func update(_ preset: ExportPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var p = preset
        p.updatedAt = Date()
        presets[idx] = p
        persist()
    }

    func remove(id: UUID) {
        let before = presets.count
        presets.removeAll { $0.id == id }
        guard presets.count != before else { return }
        persist()
    }

    func preset(id: UUID) -> ExportPreset? {
        presets.first(where: { $0.id == id })
    }

    /// Make a new preset whose `readOnceWriteMany` defaults to the
    /// library's current `defaultReadOnceWriteMany`. Callers that
    /// already have a value (Save-as-new from a shoot's current
    /// state) override after creation.
    func makeBlank(name: String) -> ExportPreset {
        ExportPreset(name: name,
                     destinations: [],
                     readOnceWriteMany: defaultReadOnceWriteMany)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.presetsKey)
    }

    private func loadOrMigrate() {
        if let data = defaults.data(forKey: Self.presetsKey),
           let decoded = try? JSONDecoder().decode([ExportPreset].self, from: data) {
            self.presets = decoded
            return
        }
        // No new-format data. Check for legacy keys; if any are
        // present, seed a single "Default" preset and clear them.
        let legacyDestinations: [ExportPreset.Destination]
        if let data = defaults.data(forKey: Self.legacyDestinationsKey),
           let decoded = try? JSONDecoder().decode([ExportPreset.Destination].self, from: data) {
            legacyDestinations = decoded
        } else {
            legacyDestinations = []
        }
        let legacyROWMValue = (defaults.object(forKey: Self.legacyROWMKey) as? Bool) ?? true
        let hasAnyLegacy = !legacyDestinations.isEmpty
            || defaults.object(forKey: Self.legacyProjectNameKey) != nil
            || defaults.object(forKey: Self.legacyROWMKey) != nil
        guard hasAnyLegacy else {
            self.presets = []
            return
        }
        let seed = ExportPreset(name: "Default",
                                destinations: legacyDestinations,
                                readOnceWriteMany: legacyROWMValue)
        self.presets = [seed]
        // Reflect the legacy global into the new default so newly
        // created presets inherit the user's prior choice.
        self.defaultReadOnceWriteMany = legacyROWMValue
        defaults.set(legacyROWMValue, forKey: Self.defaultROWMKey)
        persist()
        defaults.removeObject(forKey: Self.legacyDestinationsKey)
        defaults.removeObject(forKey: Self.legacyProjectNameKey)
        defaults.removeObject(forKey: Self.legacyROWMKey)
    }
}
