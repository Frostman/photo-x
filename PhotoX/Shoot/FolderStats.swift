import Foundation
import Observation

/// Per-folder pair counts shown on the starter screen.
struct PairCount: Hashable, Sendable {
    /// Number of unique stems with both an ARW and a HIF in the folder.
    let total: Int
    /// Number of those that also have a sibling `<stem>.xmp` file.
    let withXMP: Int
}

enum FolderState: Hashable, Sendable {
    case unknown
    case loading
    case ok(PairCount)
    case inaccessible
}

/// Counts image pairs per folder for the Favorites + Recents list on the
/// starter screen. One `contentsOfDirectory` call per folder, off-main; we
/// only stat extensions, never open or read any image / XMP. Scales fine for
/// 10k+ files (`FileManager.contentsOfDirectory` is a single getdirentries
/// loop on macOS).
@MainActor
@Observable
final class FolderStats {
    private(set) var stats: [String: FolderState] = [:]

    /// Recompute counts for the given paths. Each path is reset to .loading
    /// immediately, then updated when the count completes. Spawned tasks run
    /// concurrently with .utility priority so they don't compete with the UI.
    func refresh(_ paths: [String]) {
        for path in paths {
            stats[path] = .loading
            Task.detached(priority: .utility) { [weak self] in
                let result = Self.compute(for: path)
                await MainActor.run { [weak self] in
                    self?.stats[path] = result
                }
            }
        }
    }

    // Read by the `nonisolated` compute(for:) below, so they must not
    // inherit the enclosing class's @MainActor isolation. Immutable Set
    // literals are trivially Sendable, so nonisolated is safe.
    nonisolated private static let rawExtensions: Set<String> = ["arw"]
    nonisolated private static let heifExtensions: Set<String> = ["hif", "heif", "heic"]

    /// Pure function. Reads directory contents in one shot; counts stems with
    /// both an ARW and a HIF (PhotoX's pair definition), and tracks how many
    /// of those have an .xmp sidecar. nonisolated so callers can hop off main.
    nonisolated private static func compute(for path: String) -> FolderState {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .inaccessible
        }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            return .inaccessible
        }

        var stems: [String: (raw: Bool, heif: Bool, xmp: Bool)] = [:]
        stems.reserveCapacity(urls.count / 2)
        for u in urls {
            let ext = u.pathExtension.lowercased()
            let isRaw = rawExtensions.contains(ext)
            let isHEIF = heifExtensions.contains(ext)
            let isXMP = ext == "xmp"
            guard isRaw || isHEIF || isXMP else { continue }
            let stem = u.deletingPathExtension().lastPathComponent
            var entry = stems[stem] ?? (false, false, false)
            if isRaw  { entry.raw  = true }
            if isHEIF { entry.heif = true }
            if isXMP  { entry.xmp  = true }
            stems[stem] = entry
        }

        var total = 0
        var withXMP = 0
        for (_, e) in stems where e.raw && e.heif {
            total += 1
            if e.xmp { withXMP += 1 }
        }
        return .ok(PairCount(total: total, withXMP: withXMP))
    }
}
