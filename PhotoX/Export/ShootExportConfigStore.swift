import CryptoKit
import Foundation

/// File-per-shoot persistence for `ShootExportConfig` values. One JSON
/// file lives at `Application Support/PhotoX/ExportConfigs/<sha>.json`
/// where `<sha>` is the SHA-256 of the shoot folder's canonical path.
///
/// File-per-shoot (rather than a single dict in UserDefaults) so that
/// concurrent writes from multiple windows can never clobber each
/// other — different shoots write disjoint files. Same-shoot concurrent
/// writes can't happen because `WindowRegistry` dedups by canonical
/// path: only one window holds a given shoot at any time.
///
/// Writes are atomic (write-temp + rename) and the file's mtime drives
/// the LRU cleanup, which trims the directory to `maxEntries` (defaults
/// to 100) once per launch on a low-priority background task. mtime is
/// refreshed on every load (`load()` touches it explicitly), every save
/// (`Data.write(.atomic)` updates it implicitly), and every export run
/// (`ExportPaneView.runExportAll/One` calls `flushPendingSave` before
/// kicking the runner). So a shoot that's actively being opened OR
/// exported from survives LRU regardless of when its config was last
/// edited.
///
/// **Presets are NOT stored here.** The global `ExportPresetsLibrary`
/// lives in UserDefaults (`export.presets`). Nothing in this store
/// can affect preset data — LRU only walks files in the
/// `ExportConfigs/` directory, and the walk filters to `.json` to
/// hedge against future adjacent files.
@MainActor
final class ShootExportConfigStore {
    static let shared = ShootExportConfigStore()

    nonisolated static let maxEntries = 100

    private let directory: URL
    private let queue: DispatchQueue

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.directory = appSupport
                .appendingPathComponent("PhotoX", isDirectory: true)
                .appendingPathComponent("ExportConfigs", isDirectory: true)
        }
        self.queue = DispatchQueue(label: "dev.frostman.photox.ShootExportConfigStore",
                                   qos: .utility)
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Synchronous load. Returns nil for new shoots (no file yet).
    /// Touches the file's mtime on a successful read so the LRU
    /// cleanup keeps shoots that are actively being opened.
    func load(forShootPath path: String) -> ShootExportConfigData? {
        let url = fileURL(forShootPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ShootExportConfigData.self, from: data) else {
            return nil
        }
        // Touch mtime so LRU treats this entry as recently used.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path)
        return decoded
    }

    /// Asynchronous save. Encodes on the calling actor (cheap), writes
    /// on the store's background queue. Atomic via `Data.write(..., .atomic)`
    /// which does the temp-file + rename swap internally.
    func save(_ data: ShootExportConfigData, forShootPath path: String) {
        let url = fileURL(forShootPath: path)
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        queue.async { [directory] in
            // Belt-and-braces: re-create the directory in case it was
            // pruned by a user cleaning up Application Support.
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try? encoded.write(to: url, options: .atomic)
        }
    }

    /// Synchronous variant for shoot-change flushes — the caller wants
    /// the previous shoot's pending state on disk before loading the
    /// next one.
    func saveSync(_ data: ShootExportConfigData, forShootPath path: String) {
        let url = fileURL(forShootPath: path)
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? encoded.write(to: url, options: .atomic)
    }

    /// Trim the directory to `keep` most-recent-by-mtime entries.
    /// `protectedPaths` are never deleted regardless of their mtime
    /// — used so currently-open shoots survive the trim.
    func purgeBeyondLRU(keep: Int = ShootExportConfigStore.maxEntries,
                        protectedPaths: Set<String> = []) {
        let dir = directory
        let protectedFiles = Set(protectedPaths.map { fileURL(forShootPath: $0).lastPathComponent })
        queue.async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { return }
            // Only consider this store's own files (.json). Skipping
            // unknown extensions is defensive — the directory should
            // never contain anything else, but a foreign file
            // accidentally dropped in must not be deleted. This is
            // also an extra hedge protecting any potential future
            // adjacent files (preset library, etc.) — though presets
            // currently live in UserDefaults, not on disk here.
            let dated: [(URL, Date)] = entries.compactMap { url in
                guard url.pathExtension.lowercased() == "json" else { return nil }
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let mtime = v?.contentModificationDate else { return nil }
                return (url, mtime)
            }
            // Sort newest-first so the first `keep` are the survivors.
            let sorted = dated.sorted { $0.1 > $1.1 }
            guard sorted.count > keep else { return }
            for (url, _) in sorted.dropFirst(keep) {
                if protectedFiles.contains(url.lastPathComponent) { continue }
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Internals

    /// Stable filename for a shoot path. Uses SHA-256 of the
    /// normalized path so different shoots can't collide and the
    /// filename is reasonably short on every filesystem.
    static func filename(forShootPath path: String) -> String {
        let canonical = ExportPathGeometry.normalize(path)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    private func fileURL(forShootPath path: String) -> URL {
        directory.appendingPathComponent(Self.filename(forShootPath: path))
    }
}

/// Codable mirror of `ShootExportConfig`'s persisted state. Kept as a
/// separate value type so the @Observable working object can hold
/// derived/computed bits (e.g. cached preset name for display when
/// the source preset was deleted) without bloating the on-disk form.
struct ShootExportConfigData: Codable, Equatable, Sendable {
    var shootPath: String
    var projectName: String
    var projectNameIsUserOverride: Bool
    var destinations: [ExportPreset.Destination]
    var readOnceWriteMany: Bool
    var sourcePresetID: UUID?
    var sourcePresetNameCached: String?
    var sourcePresetSnapshotDestinations: [ExportPreset.Destination]?
    var sourcePresetSnapshotReadOnceWriteMany: Bool?
    var sourcePresetSnapshotAt: Date?
}
