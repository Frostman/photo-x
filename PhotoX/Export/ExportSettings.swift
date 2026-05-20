import Foundation
import Observation

/// Persisted configuration for the Export feature. Singleton like
/// `FavoriteShoots` — JSON-encoded into UserDefaults so we can store the
/// nested `[Destination]` array (UserDefaults' primitive types alone can't
/// hold our struct-of-structs).
///
/// One project name + one destinations list, global across all shoots.
@MainActor
@Observable
final class ExportSettings {
    static let shared = ExportSettings()

    /// Policy applied to non-XMP files when the destination already has the
    /// file. XMPs always carry an additional "never overwrite a newer
    /// sidecar" rule on top of whichever policy is selected — see
    /// `OverwriteDecision.decide(…)`.
    enum OverwritePolicy: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
        case skipUnchangedElseOverwrite   // default
        case skipUnchangedElseNewerOnly
        case skipIfExists
        case alwaysOverwrite

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .skipUnchangedElseOverwrite:  return "Skip if same; else overwrite"
            case .skipUnchangedElseNewerOnly:  return "Skip if same; else newer only"
            case .skipIfExists:                return "Skip if file exists"
            case .alwaysOverwrite:             return "Always overwrite"
            }
        }

        var helpText: String {
            switch self {
            case .skipUnchangedElseOverwrite:
                return "Skip if size matches and modified time within 1 second; otherwise overwrite."
            case .skipUnchangedElseNewerOnly:
                return "Skip if size matches and mtime within 1 second; otherwise only copy if source is newer than destination."
            case .skipIfExists:
                return "Never overwrite — skip every file that already exists at the destination."
            case .alwaysOverwrite:
                return "Always overwrite the destination file."
            }
        }
    }

    struct Destination: Identifiable, Codable, Hashable, Sendable {
        var id: UUID = UUID()
        var path: String

        // Filter — same semantics as ViewerState.show*
        var showStars: Set<Int> = [1, 2, 3, 4, 5]
        var showRejected: Bool = true
        var showUnrated: Bool = true

        // File types
        var includeARW: Bool = true
        /// Covers both `.HIF` and `.JPG` previews. Kept under the
        /// `includeHIF` name for storage compat with existing
        /// persisted settings; the UI labels it "HIF/JPG".
        var includeHIF: Bool = true
        var includeXMP: Bool = true

        // Behaviour
        var overwrite: OverwritePolicy = .skipUnchangedElseOverwrite
        var removeOrphans: Bool = false
    }

    private(set) var projectName: String = ""
    private(set) var destinations: [Destination] = []
    /// "Export all" reads each source file once and writes to every wanting
    /// destination in one pass. Helps on slow source media (SD card readers).
    /// Per-destination Run buttons always use the simple loop regardless.
    /// Default: ON. Most exports benefit; the trade-off (slightly higher
    /// peak memory while a single source file is in flight) is irrelevant
    /// for typical RAW sizes.
    var readOnceWriteMany: Bool = true {
        didSet { defaults.set(readOnceWriteMany, forKey: Self.readOnceKey) }
    }

    private let defaults: UserDefaults
    private static let projectNameKey      = "export.projectName"
    private static let destinationsKey     = "export.destinations"
    private static let readOnceKey         = "export.readOnceWriteMany"

    /// `defaults` injectable so tests can use a per-suite UserDefaults and
    /// leave the user's real export settings untouched.
    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
        self.projectName = defaults.string(forKey: Self.projectNameKey) ?? ""
        if let data = defaults.data(forKey: Self.destinationsKey),
           let decoded = try? JSONDecoder().decode([Destination].self, from: data) {
            self.destinations = decoded
        }
        // bool(forKey:) returns false for missing keys, which would override
        // the `true` default for users who've never touched the toggle.
        // Use object(forKey:) so a missing key keeps the default.
        if let stored = defaults.object(forKey: Self.readOnceKey) as? Bool {
            self.readOnceWriteMany = stored
        }
    }

    // MARK: - Project name

    /// Whitespace-only project names are rejected for export purposes — the
    /// sheet's Export / Run buttons stay disabled until a non-empty name is
    /// set. We still STORE the raw user input (e.g. while they're typing)
    /// and validate on use.
    var isValidForExport: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setProjectName(_ name: String) {
        projectName = name
        defaults.set(name, forKey: Self.projectNameKey)
    }

    // MARK: - Destinations CRUD

    /// Outcome of `add(path:)`. Anything other than `.ok` means the
    /// path was rejected and the destinations list was NOT modified.
    /// The picker UI surfaces the rejection as an NSAlert.
    enum AddResult: Sendable, Hashable {
        case ok
        /// An existing destination has the same path (after trailing-slash
        /// normalisation).
        case duplicate
        /// The new path is INSIDE one of the existing destinations.
        /// Exporting both would write the same project subfolder in
        /// nested locations, polluting the parent.
        case nestedUnder(existingPath: String)
        /// The new path CONTAINS one of the existing destinations.
        /// Symmetric to nestedUnder; same reason to refuse.
        case containsExisting(existingPath: String)
    }

    /// Why a destination conflicts with the current shoot folder.
    /// Pre-add and pre-run both check this; pre-run also catches the
    /// case where the user added a destination and THEN opened a
    /// shoot that conflicts with it.
    enum SourceConflict: Sendable, Hashable {
        /// destPath == sourcePath
        case isSource
        /// destPath is INSIDE sourcePath. Export would write back
        /// into the originals folder.
        case insideSource
        /// sourcePath is INSIDE destPath. Orphan-prune at the
        /// destination would see the source folder as a parent of
        /// "managed" files and could delete real originals.
        case containsSource
    }

    /// Return the conflict between `destPath` and `sourcePath`,
    /// or nil if they're disjoint. Both paths are normalised
    /// first; comparison is case-sensitive (matches APFS default).
    static func sourceConflict(destPath: String,
                                sourcePath: String) -> SourceConflict? {
        let d = normalizePath(destPath)
        let s = normalizePath(sourcePath)
        if d == s { return .isSource }
        if isStrictParent(s, of: d) { return .insideSource }
        if isStrictParent(d, of: s) { return .containsSource }
        return nil
    }

    /// Re-validate every destination against the current source
    /// folder. Used at run time (Export-all and per-destination Run)
    /// — the add-time inter-destination check already ran when each
    /// destination was added, but the SOURCE folder may have changed
    /// since (user opened a different shoot whose folder collides).
    /// Returns an empty array when everything's fine.
    func sourceConflicts(againstSource sourcePath: String)
        -> [(destination: Destination, conflict: SourceConflict)] {
        destinations.compactMap { dest in
            Self.sourceConflict(destPath: dest.path, sourcePath: sourcePath)
                .map { (dest, $0) }
        }
    }

    @discardableResult
    func add(path: String) -> AddResult {
        let normalized = Self.normalizePath(path)
        for existing in destinations {
            let exNorm = Self.normalizePath(existing.path)
            if exNorm == normalized {
                return .duplicate
            }
            if Self.isStrictParent(exNorm, of: normalized) {
                return .nestedUnder(existingPath: existing.path)
            }
            if Self.isStrictParent(normalized, of: exNorm) {
                return .containsExisting(existingPath: existing.path)
            }
        }
        let dest = Destination(path: path)
        destinations.append(dest)
        persistDestinations()
        return .ok
    }

    /// Trim trailing slashes (except the root "/") so "/foo" and "/foo/"
    /// compare equal.
    static func normalizePath(_ path: String) -> String {
        var n = path
        while n.count > 1 && n.hasSuffix("/") { n.removeLast() }
        return n
    }

    /// True when `child` lives strictly INSIDE `parent` (proper descendant —
    /// the "+/+" guard prevents "/foo" matching "/foo-bar"). Both inputs
    /// must already be normalised via `normalizePath`.
    static func isStrictParent(_ parent: String, of child: String) -> Bool {
        guard child.count > parent.count else { return false }
        if parent == "/" { return child.hasPrefix("/") }
        return child.hasPrefix(parent + "/")
    }

    func remove(id: UUID) {
        let before = destinations.count
        destinations.removeAll { $0.id == id }
        guard destinations.count != before else { return }
        persistDestinations()
    }

    func update(id: UUID, _ mutate: (inout Destination) -> Void) {
        guard let idx = destinations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&destinations[idx])
        persistDestinations()
    }

    /// Reorder by moving `id` to land directly before `targetID`. Mirrors
    /// `FavoriteShoots.move(_:before:)` — same semantics, same persistence.
    func move(_ id: UUID, before targetID: UUID) {
        guard let from = destinations.firstIndex(where: { $0.id == id }),
              let to = destinations.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        var next = destinations
        let element = next.remove(at: from)
        let insertAt = from < to ? to - 1 : to
        next.insert(element, at: insertAt)
        destinations = next
        persistDestinations()
    }

    private func persistDestinations() {
        if let data = try? JSONEncoder().encode(destinations) {
            defaults.set(data, forKey: Self.destinationsKey)
        }
    }
}
