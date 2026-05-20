import Foundation

enum ShootScanner {
    /// Scan a folder for `PhotoEntry`s (ARW+HIF / ARW+JPG pairs or
    /// standalone HIF / JPG previews). Sorted by filename (which ==
    /// capture order for Sony bodies). Does NOT recurse.
    static func scan(folder url: URL) -> Shoot {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        let entries = EntryFinder.entries(in: contents)
        return Shoot(folderURL: url, entries: entries)
    }

    /// Resolves whatever the user dropped / picked into a (Shoot, focus entry):
    /// - one entry → scan its parent folder, focus on that entry
    /// - mix of files containing one or more entries → scan parent of the first
    ///   entry, focus on the first entry found in the drop
    /// - a folder → scan it, focus on the first entry
    /// - nothing pairable → nil
    static func resolve(droppedURLs urls: [URL]) -> (shoot: Shoot, focus: PhotoEntry)? {
        // Folder case: a single directory was dropped/picked.
        if urls.count == 1, isDirectory(urls[0]) {
            let shoot = scan(folder: urls[0])
            guard let first = shoot.entries.first else { return nil }
            return (shoot, first)
        }

        // Files case: find entries in the drop, then scan the parent folder of
        // the first entry so the user can ←/→ to siblings they didn't drop.
        let files = EntryFinder.expand(urls)
        guard let droppedEntry = EntryFinder.firstEntry(in: files) else { return nil }
        // Anchor on the RAW if we have one (its directory is the shoot
        // root); fall back to the preview's directory for standalone
        // HIF / JPG entries.
        let parent = (droppedEntry.rawURL ?? droppedEntry.previewURL)
            .deletingLastPathComponent()
        let shoot = scan(folder: parent)
        // Try to match the dropped entry by stem inside the scanned shoot.
        let focus = shoot.entries.first(where: { $0.stem == droppedEntry.stem }) ?? droppedEntry
        // If the scan came up empty for some reason (permissions, etc.), fall
        // back to a one-entry shoot so the user at least sees what they dropped.
        if shoot.isEmpty {
            return (Shoot(folderURL: parent, entries: [droppedEntry]), droppedEntry)
        }
        return (shoot, focus)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
