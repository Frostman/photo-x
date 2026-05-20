import Foundation

enum EntryFinder {
    private static let rawExtensions:  Set<String> = ["arw"]
    private static let heifExtensions: Set<String> = ["hif", "heif", "heic"]
    private static let jpgExtensions:  Set<String> = ["jpg", "jpeg"]

    static func firstEntry(in urls: [URL]) -> PhotoEntry? {
        entries(in: urls).first
    }

    /// Group files by stem into `PhotoEntry`s. Accepts any of:
    /// `ARW + HIF`, `ARW + JPG`, standalone `HIF`, standalone `JPG`.
    /// When both `HIF` and `JPG` exist for the same stem, `HIF` wins
    /// (matches the historical preference; users explicitly want the
    /// JPG ignored in that case). `ARW`-only entries (no preview)
    /// are dropped — out of scope.
    static func entries(in urls: [URL]) -> [PhotoEntry] {
        var byStem: [String: (raw: URL?, heif: URL?, jpg: URL?)] = [:]
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            var slot = byStem[stem] ?? (nil, nil, nil)
            if      rawExtensions.contains(ext)  { slot.raw  = url }
            else if heifExtensions.contains(ext) { slot.heif = url }
            else if jpgExtensions.contains(ext)  { slot.jpg  = url }
            else { continue }
            byStem[stem] = slot
        }
        return byStem.compactMap { stem, slot in
            guard let preview = slot.heif ?? slot.jpg else {
                return nil   // ARW-only: out of scope
            }
            return PhotoEntry(rawURL: slot.raw, previewURL: preview, stem: stem)
        }
        .sorted { $0.stem < $1.stem }
    }

    /// Expand a mixed list of file and directory URLs into a flat list of files
    /// (one level deep — we don't recurse).
    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return []
            }
            if isDir.boolValue {
                return (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )) ?? []
            }
            return [url]
        }
    }
}
