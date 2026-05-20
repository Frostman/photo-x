import Foundation

/// Pure planning step shared by both copy modes. Given entries + the
/// destination's filter/type/policy config, produces:
///   * the resolved output folder (with project name subfolder)
///   * the list of source→destination file ops to attempt
///   * the set of "eligible" stems (used by orphan removal)
///   * the total bytes to copy (for ETA)
///
/// No IO inside `plan(…)` except a single stat per source file to compute
/// `totalBytes`. The actual `decide(…)` and copy happens in the runner.
enum ExportPlanner {

    struct Plan: Sendable {
        var outputFolder: URL
        var fileOperations: [FileOperation]
        var eligibleStems: Set<String>
        var totalBytes: Int64
    }

    struct FileOperation: Sendable, Hashable {
        let sourceURL: URL
        let destinationURL: URL
        let isXMP: Bool
        let kind: Kind

        /// `preview` covers HIF / HEIF / HEIC / JPG / JPEG — they
        /// share one export toggle (`includeHIF`, displayed in the
        /// UI as "HIF/JPG"). The actual format on disk is encoded
        /// in `destinationURL.pathExtension`.
        enum Kind: String, Sendable, Hashable { case arw, preview, xmp }
    }

    /// Builds the plan. `projectName` is appended as a subfolder under the
    /// destination path; an empty / whitespace-only project name means
    /// "copy directly into `destination.path`" (matches the
    /// `isValidForExport` contract — caller should already have refused to
    /// run with an empty name, but we don't enforce that here so the
    /// planner stays pure).
    static func plan(
        entries: [PhotoEntry],
        entryXMPs: [String: XMPSidecar],
        projectName: String,
        destination: ExportSettings.Destination
    ) -> Plan {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(fileURLWithPath: destination.path)
        let outputFolder = trimmed.isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(trimmed, isDirectory: true)

        let eligible = entries.filter { matches($0, destination: destination, entryXMPs: entryXMPs) }
        let eligibleStems = Set(eligible.map(\.stem))

        var ops: [FileOperation] = []
        var totalBytes: Int64 = 0
        let fm = FileManager.default

        for entry in eligible {
            if let raw = entry.rawURL, destination.includeARW {
                let dst = outputFolder.appendingPathComponent(raw.lastPathComponent)
                ops.append(.init(sourceURL: raw, destinationURL: dst,
                                 isXMP: false, kind: .arw))
                totalBytes += sizeOf(raw, fm: fm)
            }
            // `includeHIF` is the persisted field name for storage
            // compat; the UI label is "HIF/JPG" — one toggle covers
            // whichever preview format the entry actually has.
            if destination.includeHIF {
                let dst = outputFolder.appendingPathComponent(entry.previewURL.lastPathComponent)
                ops.append(.init(sourceURL: entry.previewURL, destinationURL: dst,
                                 isXMP: false, kind: .preview))
                totalBytes += sizeOf(entry.previewURL, fm: fm)
            }
            if destination.includeXMP {
                let xmpSrc = entry.xmpURL
                // Only include if the source XMP actually exists on disk —
                // empty entries (no sidecar yet) shouldn't appear in the
                // plan for XMP, otherwise the copy loop counts a phantom
                // skip.
                if fm.fileExists(atPath: xmpSrc.path) {
                    let dst = outputFolder.appendingPathComponent(xmpSrc.lastPathComponent)
                    ops.append(.init(sourceURL: xmpSrc, destinationURL: dst,
                                     isXMP: true, kind: .xmp))
                    totalBytes += sizeOf(xmpSrc, fm: fm)
                }
            }
        }

        return Plan(outputFolder: outputFolder, fileOperations: ops,
                    eligibleStems: eligibleStems, totalBytes: totalBytes)
    }

    /// Mirror of `ViewerState.RatingCategory` matching, duplicated here so
    /// the runner doesn't depend on ViewerState.
    private static func matches(
        _ entry: PhotoEntry,
        destination: ExportSettings.Destination,
        entryXMPs: [String: XMPSidecar]
    ) -> Bool {
        let xmp = entryXMPs[entry.stem] ?? .empty
        if xmp.isReject { return destination.showRejected }
        if let stars = xmp.starCount, stars > 0 {
            return destination.showStars.contains(stars)
        }
        return destination.showUnrated
    }

    static func xmpURL(for entry: PhotoEntry) -> URL { entry.xmpURL }

    private static func sizeOf(_ url: URL, fm: FileManager) -> Int64 {
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        if let n = attrs[.size] as? Int64 { return n }
        if let n = (attrs[.size] as? NSNumber)?.int64Value { return n }
        return 0
    }
}
