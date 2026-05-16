import Foundation

enum ShootScanner {
    /// Scan a folder for ARW + HIF pairs. Sort by filename (which == capture
    /// order for Sony bodies — DSC04177.ARW comes before DSC04178.ARW). Does
    /// NOT recurse into subdirectories.
    static func scan(folder url: URL) -> Shoot {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        let pairs = PairFinder.pairs(in: contents)
        return Shoot(folderURL: url, pairs: pairs)
    }

    /// Resolves whatever the user dropped / picked into a (Shoot, focus pair):
    /// - one pair → scan its parent folder, focus on that pair
    /// - mix of files containing one or more pairs → scan parent of the first
    ///   pair, focus on the first pair found in the drop
    /// - a folder → scan it, focus on the first pair
    /// - nothing pairable → nil
    static func resolve(droppedURLs urls: [URL]) -> (shoot: Shoot, focus: PhotoPair)? {
        // Folder case: a single directory was dropped/picked.
        if urls.count == 1, isDirectory(urls[0]) {
            let shoot = scan(folder: urls[0])
            guard let first = shoot.pairs.first else { return nil }
            return (shoot, first)
        }

        // Files case: find pairs in the drop, then scan the parent folder of
        // the first pair so the user can ←/→ to siblings they didn't drop.
        let files = PairFinder.expand(urls)
        guard let droppedPair = PairFinder.firstPair(in: files) else { return nil }
        let parent = droppedPair.rawURL.deletingLastPathComponent()
        let shoot = scan(folder: parent)
        // Try to match the dropped pair by stem inside the scanned shoot.
        let focus = shoot.pairs.first(where: { $0.stem == droppedPair.stem }) ?? droppedPair
        // If the scan came up empty for some reason (permissions, etc.), fall
        // back to a one-pair shoot so the user at least sees what they dropped.
        if shoot.isEmpty {
            return (Shoot(folderURL: parent, pairs: [droppedPair]), droppedPair)
        }
        return (shoot, focus)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
