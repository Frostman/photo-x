import Foundation

enum PairFinder {
    private static let rawExtensions: Set<String> = ["arw"]
    private static let heifExtensions: Set<String> = ["hif", "heif", "heic"]

    static func firstPair(in urls: [URL]) -> PhotoPair? {
        pairs(in: urls).first
    }

    static func pairs(in urls: [URL]) -> [PhotoPair] {
        var byStem: [String: (raw: URL?, heif: URL?)] = [:]
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            var entry = byStem[stem] ?? (nil, nil)
            if rawExtensions.contains(ext) {
                entry.raw = url
            } else if heifExtensions.contains(ext) {
                entry.heif = url
            } else {
                continue
            }
            byStem[stem] = entry
        }
        return byStem.compactMap { stem, urls in
            guard let raw = urls.raw, let heif = urls.heif else { return nil }
            return PhotoPair(rawURL: raw, heifURL: heif, stem: stem)
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
