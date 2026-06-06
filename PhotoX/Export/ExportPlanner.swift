import Foundation
import IndexingCore

/// Pure planning step shared by both copy modes. Given entries + the
/// destination's filter/type/policy config, produces:
///   * the resolved output folder (with project name subfolder)
///   * the list of source→destination file ops to attempt
///   * the set of "eligible" stems (used by orphan removal)
///   * the total bytes to copy (for ETA)
///
/// No IO inside `plan(…)` except a single stat per source file to compute
/// `totalBytes` — and only when the caller didn't pre-supply a
/// `sourceSizes` cache. `ExportRunner` always pre-stats once and shares
/// the map across every destination's plan to avoid N×M stats on slow
/// source media; the cache-less fallback exists for tests and one-off
/// callers.
/// The actual `decide(…)` and copy happens in the runner.
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
        destination: ExportPreset.Destination,
        sourceSizes: [URL: Int64]? = nil
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
                totalBytes += sizeOf(raw, fm: fm, cache: sourceSizes)
            }
            // `includeHIF` is the persisted field name for storage
            // compat; the UI label is "HIF/JPG" — one toggle covers
            // whichever preview format the entry actually has.
            if destination.includeHIF {
                let dst = outputFolder.appendingPathComponent(entry.previewURL.lastPathComponent)
                ops.append(.init(sourceURL: entry.previewURL, destinationURL: dst,
                                 isXMP: false, kind: .preview))
                totalBytes += sizeOf(entry.previewURL, fm: fm, cache: sourceSizes)
            }
            if destination.includeXMP {
                let xmpSrc = entry.xmpURL
                // Only include if the source XMP actually exists on disk —
                // empty entries (no sidecar yet) shouldn't appear in the
                // plan for XMP, otherwise the copy loop counts a phantom
                // skip. When the caller supplied a `sourceSizes` cache,
                // a present key proves the XMP existed at pre-stat
                // time — skip the redundant existence check.
                let xmpExists: Bool
                if let cache = sourceSizes {
                    xmpExists = cache[xmpSrc] != nil
                } else {
                    xmpExists = fm.fileExists(atPath: xmpSrc.path)
                }
                if xmpExists {
                    let dst = outputFolder.appendingPathComponent(xmpSrc.lastPathComponent)
                    ops.append(.init(sourceURL: xmpSrc, destinationURL: dst,
                                     isXMP: true, kind: .xmp))
                    totalBytes += sizeOf(xmpSrc, fm: fm, cache: sourceSizes)
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
        destination: ExportPreset.Destination,
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

    private static func sizeOf(_ url: URL, fm: FileManager, cache: [URL: Int64]?) -> Int64 {
        if let cached = cache?[url] { return cached }
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        if let n = attrs[.size] as? Int64 { return n }
        if let n = (attrs[.size] as? NSNumber)?.int64Value { return n }
        return 0
    }

    // MARK: - Planning phase

    /// Runs the source stat sweep + per-destination
    /// readdir+stat passes concurrently via a `TaskGroup`,
    /// reporting progress per task into `progress` so each
    /// card on the Export tab renders its own bar.
    ///
    /// Always awaits every subtask before returning so
    /// callers can treat the result as fully computed —
    /// no partial state to defend against downstream.
    ///
    /// Per-destination "blocked" decision is made here: if
    /// `<dest.path>/<projectName>/` has non-hidden items
    /// AND the destination's `allowNonEmpty` toggle is off,
    /// `DestinationPlan.blockedReason` is set so the runner
    /// can short-circuit that destination's copy to a
    /// `.failed` state without touching the disk again.
    @MainActor
    static func runPlanningPhase(
        entries: [PhotoEntry],
        projectName: String,
        destinations: [ExportPreset.Destination],
        progress: PlanningPhaseProgress
    ) async -> ExportPlanningResult {
        // Register destination progress slots up-front so the
        // UI can bind to them before any subtask runs — no
        // "registered after first redraw" gap.
        for dest in destinations { progress.registerDestination(dest.id) }
        let trimmedProject = projectName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Snapshot the source URLs the source-task needs to
        // stat. Each entry contributes its rawURL (if any),
        // its previewURL (always), and its xmpURL (only if
        // the file actually exists on disk).
        let sourceURLs: [URL] = {
            var out: [URL] = []
            let fm = FileManager.default
            for entry in entries {
                if let raw = entry.rawURL { out.append(raw) }
                out.append(entry.previewURL)
                let xmp = entry.xmpURL
                if fm.fileExists(atPath: xmp.path) { out.append(xmp) }
            }
            return out
        }()
        progress.source.setTotal(sourceURLs.count)

        // Capture the destination-progress references once
        // (off the dict) so subtasks don't have to bounce
        // through MainActor just to look up their slot.
        let destProgressByID: [UUID: TaskProgress] = progress.destinations
        let sourceProgress = progress.source

        return await withTaskGroup(of: PlanningSubtaskOutcome.self) { group in
            // Source-side stat sweep.
            group.addTask(priority: .userInitiated) {
                var sizes: [URL: Int64] = [:]
                var errs: [(URL, String)] = []
                let fm = FileManager.default
                for url in sourceURLs {
                    do {
                        let attrs = try fm.attributesOfItem(atPath: url.path)
                        let sz = (attrs[.size] as? Int64)
                            ?? (attrs[.size] as? NSNumber)?.int64Value
                            ?? 0
                        sizes[url] = sz
                    } catch {
                        errs.append((url, error.localizedDescription))
                    }
                    await sourceProgress.bump()
                }
                if !errs.isEmpty {
                    let snapshot = errs
                    await MainActor.run {
                        for (u, m) in snapshot { sourceProgress.recordError(u, m) }
                    }
                }
                return .source(sizes: sizes, errors: errs)
            }

            // Per-destination readdir + emptiness check.
            for dest in destinations {
                let destProgress = destProgressByID[dest.id]
                let allowNonEmpty = dest.allowNonEmpty
                let destID = dest.id
                let path = dest.path
                let project = trimmedProject
                group.addTask(priority: .userInitiated) {
                    let fm = FileManager.default
                    let projectURL: URL = project.isEmpty
                        ? URL(fileURLWithPath: path)
                        : URL(fileURLWithPath: path).appendingPathComponent(project)
                    var existing: Set<String> = []
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: projectURL.path, isDirectory: &isDir),
                       isDir.boolValue,
                       let items = try? fm.contentsOfDirectory(
                            at: projectURL,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]) {
                        existing = Set(items.map { $0.lastPathComponent })
                    }
                    // We don't have per-item progress for a
                    // readdir (it's atomic) but setting
                    // total=done=1 gives the UI a "this task
                    // is finished" signal it can render as a
                    // full bar / hidden state.
                    if let dp = destProgress {
                        await MainActor.run {
                            dp.setTotal(1)
                            dp.bump(1)
                        }
                    }
                    let blockedReason: String? = (!existing.isEmpty && !allowNonEmpty)
                        ? "Destination not empty — turn on \"Allow non-empty\" to overlay onto an existing project folder."
                        : nil
                    return .destination(id: destID,
                                        plan: DestinationPlan(existingFilenames: existing,
                                                              blockedReason: blockedReason))
                }
            }

            // Collect outcomes.
            var sourceSizes: [URL: Int64] = [:]
            var sourceErrors: [(URL, String)] = []
            var perDestination: [UUID: DestinationPlan] = [:]
            for await outcome in group {
                switch outcome {
                case .source(let sizes, let errs):
                    sourceSizes = sizes
                    sourceErrors = errs
                case .destination(let id, let plan):
                    perDestination[id] = plan
                }
            }
            return ExportPlanningResult(
                sourceSizes: sourceSizes,
                perDestination: perDestination,
                sourceErrors: sourceErrors
            )
        }
    }

    /// Discriminated union for `runPlanningPhase`'s
    /// `TaskGroup` collection. Each subtask returns exactly
    /// one of these so the collector can demux into the
    /// shared result struct without any actor hopping.
    private enum PlanningSubtaskOutcome: Sendable {
        case source(sizes: [URL: Int64], errors: [(URL, String)])
        case destination(id: UUID, plan: DestinationPlan)
    }
}
