import Foundation

public enum ShootScanner {
    /// Scan a folder for `PhotoEntry`s (ARW+HIF / ARW+JPG pairs or
    /// standalone HIF / JPG previews) and harvest every byte of
    /// metadata the macOS app needs for the shoot-open pre-pass
    /// from the same directory listing. Sorted by filename (which
    /// == capture order for Sony bodies). Does NOT recurse.
    ///
    /// The single `contentsOfDirectory(at:includingPropertiesForKeys:options:)`
    /// call asks the filesystem for size + mtime alongside the
    /// listing — on SMB this is one `FILE_DIRECTORY_INFORMATION`
    /// round-trip instead of one stat per file. The resulting URLs
    /// have those values cached on the URL object, so the
    /// `previewFingerprints` harvest below doesn't re-stat.
    public static func scan(folder url: URL) -> Shoot {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        let entries = EntryFinder.entries(in: contents)

        // Harvest previewFingerprints from each entry's previewURL.
        // The URL came back from contentsOfDirectory with the size
        // + mtime resource values cached — `resourceValues(forKeys:)`
        // doesn't issue a fresh stat.
        var previewFingerprints: [String: IndexFingerprint] = [:]
        previewFingerprints.reserveCapacity(entries.count)
        for entry in entries {
            if let fp = fingerprint(from: entry.previewURL, keys: keys) {
                previewFingerprints[entry.stem] = fp
            }
        }

        // Build xmpStems from the listing — any .xmp sibling whose
        // stem also appears in `entries`. Detached .xmp files
        // (no matching photo) are ignored.
        let entryStems = Set(entries.map(\.stem))
        var xmpStems: Set<String> = []
        for url in contents where url.pathExtension.lowercased() == "xmp" {
            let stem = url.deletingPathExtension().lastPathComponent
            if entryStems.contains(stem) {
                xmpStems.insert(stem)
            }
        }

        return Shoot(folderURL: url,
                     entries: entries,
                     previewFingerprints: previewFingerprints,
                     xmpStems: xmpStems)
    }

    /// Read size + mtime from a URL's cached resource values (set
    /// during the parent `contentsOfDirectory` call) and convert
    /// to an `IndexFingerprint`. Returns nil if either value is
    /// missing — caller treats that stem as "unknown fingerprint"
    /// and skips the cache lookup (entry then goes through the
    /// normal indexing path).
    private static func fingerprint(from url: URL,
                                    keys: Set<URLResourceKey>) -> IndexFingerprint? {
        guard let values = try? url.resourceValues(forKeys: keys),
              let size = values.fileSize,
              let mtime = values.contentModificationDate else {
            return nil
        }
        let mtimeNanos = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
        return IndexFingerprint(size: Int64(size), mtimeNanos: mtimeNanos)
    }

    /// Resolves whatever the user dropped / picked into a (Shoot, focus entry):
    /// - one entry → scan its parent folder, focus on that entry
    /// - mix of files containing one or more entries → scan parent of the first
    ///   entry, focus on the first entry found in the drop
    /// - a folder → scan it, focus on the first entry
    /// - nothing pairable → nil
    public static func resolve(droppedURLs urls: [URL]) -> (shoot: Shoot, focus: PhotoEntry)? {
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
