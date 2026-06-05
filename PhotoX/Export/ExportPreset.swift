import Foundation

/// A named, reusable bundle of destinations that represents one of the
/// user's export workflows ("card-cull", "nas-cull", "nas-reorg", …).
/// Presets are global to the app; per-shoot Export panes pick one as
/// their starting point and snapshot it into their working state.
/// Local edits in a shoot don't touch the preset — the user explicitly
/// saves back, saves as new, or saves overwriting a different preset.
struct ExportPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var destinations: [Destination]
    /// "Export all" reads each source file once and writes to every
    /// wanting destination in one pass. Per-preset because different
    /// workflows have different source-media characteristics (card
    /// reader vs. NAS) and want different defaults.
    var readOnceWriteMany: Bool
    /// Bumped on every mutation via `ExportPresetsLibrary.update(_:)`.
    /// Compared against `ShootExportConfig.sourcePresetSnapshotAt` to
    /// detect "preset changed since you applied it" in any shoot.
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         destinations: [Destination] = [],
         readOnceWriteMany: Bool,
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.destinations = destinations
        self.readOnceWriteMany = readOnceWriteMany
        self.updatedAt = updatedAt
    }

    /// Same fields the singleton `ExportSettings.Destination` had.
    /// Kept under `ExportPreset.Destination` so the new namespace is
    /// self-contained: every Export-related type lives under
    /// `ExportPreset.*` or `ShootExportConfig.*`.
    struct Destination: Identifiable, Codable, Hashable, Sendable {
        var id: UUID = UUID()
        var path: String

        var showStars: Set<Int> = [1, 2, 3, 4, 5]
        var showRejected: Bool = true
        var showUnrated: Bool = true

        var includeARW: Bool = true
        /// Covers both `.HIF` and `.JPG` previews. Kept under the
        /// `includeHIF` name for storage compat with the legacy
        /// singleton's JSON; the UI labels it "HIF/JPG".
        var includeHIF: Bool = true
        var includeXMP: Bool = true

        var overwrite: OverwritePolicy = .skipUnchangedElseOverwrite
        var allowNonEmpty: Bool = false
        var removeOrphans: Bool = false

        init(id: UUID = UUID(), path: String,
             showStars: Set<Int> = [1, 2, 3, 4, 5],
             showRejected: Bool = true, showUnrated: Bool = true,
             includeARW: Bool = true, includeHIF: Bool = true, includeXMP: Bool = true,
             overwrite: OverwritePolicy = .skipUnchangedElseOverwrite,
             allowNonEmpty: Bool = false,
             removeOrphans: Bool = false) {
            self.id = id
            self.path = path
            self.showStars = showStars
            self.showRejected = showRejected
            self.showUnrated = showUnrated
            self.includeARW = includeARW
            self.includeHIF = includeHIF
            self.includeXMP = includeXMP
            self.overwrite = overwrite
            self.allowNonEmpty = allowNonEmpty
            self.removeOrphans = removeOrphans
        }

        // Custom decoder: synthesized one ignores stored-property
        // defaults, so adding a new field would wipe every persisted
        // destination on the next launch. decodeIfPresent ?? default
        // restores the same value the memberwise init would use.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id            = try c.decodeIfPresent(UUID.self,            forKey: .id) ?? UUID()
            self.path          = try c.decode(String.self,                   forKey: .path)
            self.showStars     = try c.decodeIfPresent(Set<Int>.self,        forKey: .showStars) ?? [1, 2, 3, 4, 5]
            self.showRejected  = try c.decodeIfPresent(Bool.self,            forKey: .showRejected) ?? true
            self.showUnrated   = try c.decodeIfPresent(Bool.self,            forKey: .showUnrated) ?? true
            self.includeARW    = try c.decodeIfPresent(Bool.self,            forKey: .includeARW) ?? true
            self.includeHIF    = try c.decodeIfPresent(Bool.self,            forKey: .includeHIF) ?? true
            self.includeXMP    = try c.decodeIfPresent(Bool.self,            forKey: .includeXMP) ?? true
            self.overwrite     = try c.decodeIfPresent(OverwritePolicy.self, forKey: .overwrite) ?? .skipUnchangedElseOverwrite
            self.allowNonEmpty = try c.decodeIfPresent(Bool.self,            forKey: .allowNonEmpty) ?? false
            self.removeOrphans = try c.decodeIfPresent(Bool.self,            forKey: .removeOrphans) ?? false
        }
    }

    /// Policy applied to non-XMP files when the destination already
    /// has the file. XMPs always carry an additional "never overwrite
    /// a newer sidecar" rule on top — see `OverwriteDecision.decide(…)`.
    enum OverwritePolicy: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
        case skipUnchangedElseOverwrite
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

    /// Outcome of `ShootExportConfig.add(path:)`. Anything other than
    /// `.ok` means the path was rejected and the destinations list
    /// was NOT modified. The picker UI surfaces the rejection as an
    /// NSAlert.
    enum AddResult: Sendable, Hashable {
        case ok
        case duplicate
        case nestedUnder(existingPath: String)
        case containsExisting(existingPath: String)
    }

    /// Why a destination conflicts with the current shoot folder.
    enum SourceConflict: Sendable, Hashable {
        case isSource
        case insideSource
        case containsSource
    }
}

/// Path geometry helpers shared between `ShootExportConfig` and any
/// pre-flight conflict checks. Pure, no dependencies on UI or
/// persistence layers.
enum ExportPathGeometry {
    /// Trim trailing slashes (except the root "/") so "/foo" and "/foo/"
    /// compare equal.
    static func normalize(_ path: String) -> String {
        var n = path
        while n.count > 1 && n.hasSuffix("/") { n.removeLast() }
        return n
    }

    /// True when `child` lives strictly INSIDE `parent` (proper
    /// descendant — the "+/+" guard prevents "/foo" matching
    /// "/foo-bar"). Both inputs must already be normalised.
    static func isStrictParent(_ parent: String, of child: String) -> Bool {
        guard child.count > parent.count else { return false }
        if parent == "/" { return child.hasPrefix("/") }
        return child.hasPrefix(parent + "/")
    }

    /// Return the conflict between `destPath` and `sourcePath`, or nil
    /// if they're disjoint.
    static func sourceConflict(destPath: String,
                                sourcePath: String) -> ExportPreset.SourceConflict? {
        let d = normalize(destPath)
        let s = normalize(sourcePath)
        if d == s { return .isSource }
        if isStrictParent(s, of: d) { return .insideSource }
        if isStrictParent(d, of: s) { return .containsSource }
        return nil
    }
}
