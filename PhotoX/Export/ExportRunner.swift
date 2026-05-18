import Foundation
import Observation

/// The in-flight engine that does the actual file copies for the Export
/// feature. Singleton because state (per-destination progress, overall
/// percent, current filename, etc.) must outlive any single sheet open
/// — the user can close the sheet and the toolbar pill keeps reporting
/// progress.
///
/// `ExportRunner` deliberately doesn't own a `ViewerState` or `Shoot` —
/// callers pass `pairs` + `pairXMPs` BY VALUE at start, so the run is
/// independent of subsequent navigation / shoot close.
@MainActor
@Observable
final class ExportRunner {
    static let shared = ExportRunner()

    // MARK: - Public state

    enum DestinationState: Sendable {
        case idle
        case queued
        case running(Progress)
        case done(Summary)
        case cancelled(Summary)
        case failed(String, Summary?)
    }

    struct Progress: Sendable, Hashable {
        var copied: Int
        var skipped: Int
        var deletedSoFar: Int
        var total: Int            // total files attempted (ARW+HIF+XMP each count once)
        var bytesCopied: Int64
        var totalBytes: Int64
        var currentFilename: String?
        var startedAt: Date

        var percent: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1.0, Double(bytesCopied) / Double(totalBytes))
        }

        /// ETA based on the observed copy rate. Returns nil for the first
        /// fraction of a second when we don't yet have a meaningful rate.
        var eta: TimeInterval? {
            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed > 0.5, bytesCopied > 0 else { return nil }
            let rate = Double(bytesCopied) / elapsed       // bytes/sec
            let remaining = Double(max(0, totalBytes - bytesCopied))
            return remaining / max(1, rate)
        }
    }

    struct Summary: Sendable, Hashable {
        var copied: Int
        var skipped: Int
        var deleted: Int
        var errors: [ErrorEntry]
        var elapsed: TimeInterval

        struct ErrorEntry: Sendable, Hashable {
            var file: String
            var message: String
        }
    }

    /// Per-destination state map. UUIDs come from `ExportSettings.Destination.id`.
    private(set) var perDestination: [UUID: DestinationState] = [:]

    /// Aggregate progress across the CURRENT batch (one Run / one Export-all
    /// invocation). Includes already-finished destinations + the running
    /// one + the queued ones — so the toolbar pill shows true batch-wide
    /// %/ETA rather than just the in-flight destination's slice.
    /// Set when the batch starts; cleared when it finishes.
    private(set) var batchProgress: BatchProgress?

    struct BatchProgress: Sendable, Hashable {
        var filesDone: Int        // copied + skipped across all dests
        var filesTotal: Int
        var bytesCopied: Int64
        var bytesTotal: Int64
        var startedAt: Date

        var percent: Double {
            guard bytesTotal > 0 else { return 0 }
            return min(1.0, Double(bytesCopied) / Double(bytesTotal))
        }

        var eta: TimeInterval? {
            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed > 0.5, bytesCopied > 0 else { return nil }
            let rate = Double(bytesCopied) / elapsed
            let remaining = Double(max(0, bytesTotal - bytesCopied))
            return remaining / max(1, rate)
        }
    }

    var isRunning: Bool {
        perDestination.values.contains { state in
            if case .running = state { return true }
            return false
        }
    }

    var hasQueued: Bool {
        perDestination.values.contains { state in
            if case .queued = state { return true }
            return false
        }
    }

    /// Aggregated progress across all currently-running destinations.
    /// Returns nil if nothing is running.
    var overallProgress: Progress? {
        let running: [Progress] = perDestination.values.compactMap {
            if case .running(let p) = $0 { return p }
            return nil
        }
        guard !running.isEmpty else { return nil }
        let copied = running.reduce(0) { $0 + $1.copied }
        let skipped = running.reduce(0) { $0 + $1.skipped }
        let deleted = running.reduce(0) { $0 + $1.deletedSoFar }
        let total = running.reduce(0) { $0 + $1.total }
        let bytesCopied = running.reduce(Int64(0)) { $0 + $1.bytesCopied }
        let totalBytes = running.reduce(Int64(0)) { $0 + $1.totalBytes }
        let startedAt = running.compactMap { $0.startedAt }.min() ?? Date()
        return Progress(copied: copied, skipped: skipped, deletedSoFar: deleted,
                        total: total, bytesCopied: bytesCopied, totalBytes: totalBytes,
                        currentFilename: nil, startedAt: startedAt)
    }

    // MARK: - Lifecycle

    /// Cancellation token per destination. When the user cancels (whole or
    /// specific), we flip the token; the copy loop checks it between files.
    private var cancellationTokens: [UUID: CancellationToken] = [:]
    /// Tracks the running `Task` per destination so we can `await` completion
    /// or trigger cancellation cleanly from tests.
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    final class CancellationToken: @unchecked Sendable {
        private var _cancelled = false
        private let lock = NSLock()
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cancelled
        }
        func cancel() {
            lock.lock(); _cancelled = true; lock.unlock()
        }
    }

    // MARK: - Public entry points

    /// Run all given destinations sequentially. Per-destination notifications
    /// are emitted for every destination EXCEPT the last; a single
    /// "all done" notification fires after the loop. The caller is
    /// responsible for confirming `removeOrphans` with the user before this
    /// is called.
    ///
    /// `sharedRead` enables Mode B: each source file is read once across all
    /// destinations that want a write. Per-destination Run buttons always
    /// take the simple per-destination loop.
    func startAll(
        pairs: [PhotoPair],
        pairXMPs: [String: XMPSidecar],
        projectName: String,
        destinations: [ExportSettings.Destination],
        sharedRead: Bool = false,
        notifications: ExportNotificationsAdapter = .live
    ) {
        guard !destinations.isEmpty else { return }
        for dest in destinations {
            perDestination[dest.id] = .queued
            cancellationTokens[dest.id] = CancellationToken()
        }
        let task = Task { [weak self] in
            guard let self else { return }
            // Compute batch totals off-main (planning stats every source file).
            let plans: [ExportPlanner.Plan] = await Task.detached(priority: .userInitiated) {
                destinations.map { dest in
                    ExportPlanner.plan(pairs: pairs, pairXMPs: pairXMPs,
                                       projectName: projectName, destination: dest)
                }
            }.value
            let totalFiles = plans.reduce(0) { $0 + $1.fileOperations.count }
            let totalBytes = plans.reduce(Int64(0)) { $0 + $1.totalBytes }
            self.batchProgress = BatchProgress(
                filesDone: 0, filesTotal: totalFiles,
                bytesCopied: 0, bytesTotal: totalBytes,
                startedAt: Date()
            )

            let summaries: [(ExportSettings.Destination, Summary)]
            if sharedRead {
                summaries = await self.runAllSharedRead(
                    pairs: pairs, pairXMPs: pairXMPs,
                    projectName: projectName, destinations: destinations
                )
            } else {
                summaries = await self.runAllSequential(
                    pairs: pairs, pairXMPs: pairXMPs,
                    projectName: projectName, destinations: destinations,
                    notifications: notifications
                )
            }
            if sharedRead {
                for (idx, (dest, summary)) in summaries.enumerated() {
                    if idx == summaries.count - 1 { continue }
                    notifications.postDestinationComplete(dest, summary)
                }
            }
            notifications.postAllComplete(summaries)
            self.batchProgress = nil
        }
        runningTasks[Self.batchSentinelID] = task
    }

    private func runAllSequential(
        pairs: [PhotoPair],
        pairXMPs: [String: XMPSidecar],
        projectName: String,
        destinations: [ExportSettings.Destination],
        notifications: ExportNotificationsAdapter
    ) async -> [(ExportSettings.Destination, Summary)] {
        var summaries: [(ExportSettings.Destination, Summary)] = []
        for (idx, dest) in destinations.enumerated() {
            if cancellationTokens[dest.id]?.isCancelled == true {
                perDestination[dest.id] = .cancelled(.empty)
                continue
            }
            let isLast = (idx == destinations.count - 1)
            let summary = await self.runSingle(
                destination: dest, pairs: pairs, pairXMPs: pairXMPs,
                projectName: projectName
            )
            summaries.append((dest, summary))
            if !isLast {
                notifications.postDestinationComplete(dest, summary)
            }
        }
        return summaries
    }

    /// Run a single destination. Posts one completion notification.
    func startOne(
        _ destinationID: UUID,
        pairs: [PhotoPair],
        pairXMPs: [String: XMPSidecar],
        projectName: String,
        destination: ExportSettings.Destination,
        notifications: ExportNotificationsAdapter = .live
    ) {
        perDestination[destinationID] = .queued
        cancellationTokens[destinationID] = CancellationToken()
        let task = Task { [weak self] in
            guard let self else { return }
            // Per-row Run is a "batch" of one as far as the toolbar pill is
            // concerned. Plan upfront so batchProgress has accurate totals.
            let plan: ExportPlanner.Plan = await Task.detached(priority: .userInitiated) {
                ExportPlanner.plan(pairs: pairs, pairXMPs: pairXMPs,
                                   projectName: projectName, destination: destination)
            }.value
            self.batchProgress = BatchProgress(
                filesDone: 0, filesTotal: plan.fileOperations.count,
                bytesCopied: 0, bytesTotal: plan.totalBytes,
                startedAt: Date()
            )
            let summary = await self.runSingle(
                destination: destination, pairs: pairs, pairXMPs: pairXMPs,
                projectName: projectName
            )
            notifications.postDestinationComplete(destination, summary)
            self.batchProgress = nil
        }
        runningTasks[destinationID] = task
    }

    func cancelAll() {
        for token in cancellationTokens.values { token.cancel() }
    }

    func cancel(_ destinationID: UUID) {
        cancellationTokens[destinationID]?.cancel()
    }

    /// Test helper: await every in-flight task to completion.
    func waitForCompletion() async {
        let tasks = Array(runningTasks.values)
        for task in tasks { await task.value }
    }

    /// Sentinel ID used to track the "startAll" Task so cancelAll() can wait
    /// for it in tests.
    private static let batchSentinelID = UUID()

    // MARK: - Single-destination run (Mode A)

    /// Returns the final Summary. Updates `perDestination[dest.id]` as it
    /// progresses. Caller is responsible for emitting any notification.
    private func runSingle(
        destination dest: ExportSettings.Destination,
        pairs: [PhotoPair],
        pairXMPs: [String: XMPSidecar],
        projectName: String
    ) async -> Summary {
        let token = cancellationTokens[dest.id] ?? CancellationToken()
        let plan = ExportPlanner.plan(
            pairs: pairs, pairXMPs: pairXMPs,
            projectName: projectName, destination: dest
        )

        var progress = Progress(
            copied: 0, skipped: 0, deletedSoFar: 0,
            total: plan.fileOperations.count,
            bytesCopied: 0, totalBytes: plan.totalBytes,
            currentFilename: nil, startedAt: Date()
        )
        perDestination[dest.id] = .running(progress)

        var errors: [Summary.ErrorEntry] = []
        // mkdir -p the output folder, off main. On SMB / NFS shares even
        // single FileManager calls can block for seconds, which would freeze
        // the UI if we ran them inline on the MainActor.
        let mkdirResult: String? = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: plan.outputFolder, withIntermediateDirectories: true)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let err = mkdirResult {
            let summary = Summary(copied: 0, skipped: 0, deleted: 0,
                                  errors: [.init(file: plan.outputFolder.path, message: err)],
                                  elapsed: Date().timeIntervalSince(progress.startedAt))
            perDestination[dest.id] = .failed(err, summary)
            return summary
        }

        for op in plan.fileOperations {
            if token.isCancelled { break }
            progress.currentFilename = op.sourceURL.lastPathComponent
            perDestination[dest.id] = .running(progress)

            let policy = dest.overwrite
            // All per-file I/O happens off-main — copies + stats. We hop
            // back to MainActor after each file to update progress.
            let outcome: FileOutcome = await Task.detached(priority: .userInitiated) {
                let srcSnap = FileSystemSnapshot.snap(op.sourceURL)
                let dstSnap = FileSystemSnapshot.snap(op.destinationURL)
                let decision = OverwriteDecision.decide(
                    source: srcSnap, destination: dstSnap,
                    isXMP: op.isXMP, policy: policy
                )
                switch decision {
                case .skip:
                    return .skipped
                case .write(let removeFirst):
                    do {
                        try Self.atomicCopy(
                            from: op.sourceURL,
                            to: op.destinationURL,
                            destExists: removeFirst
                        )
                        return .copied(bytes: srcSnap.size ?? 0)
                    } catch {
                        return .errored(error.localizedDescription)
                    }
                }
            }.value

            switch outcome {
            case .skipped:
                progress.skipped += 1
                bumpBatch(filesDelta: 1, bytesDelta: 0)
            case .copied(let bytes):
                progress.copied += 1
                progress.bytesCopied += bytes
                bumpBatch(filesDelta: 1, bytesDelta: bytes)
            case .errored(let msg):
                errors.append(.init(file: op.sourceURL.lastPathComponent, message: msg))
            }
            perDestination[dest.id] = .running(progress)
        }

        // Orphan removal phase (per destination). Only runs if not cancelled.
        var deleted = 0
        if !token.isCancelled, dest.removeOrphans {
            let eligible = plan.eligibleStems
            let folder = plan.outputFolder
            let removalResult: (deleted: Int, errors: [Summary.ErrorEntry]) =
                await Task.detached(priority: .userInitiated) {
                    Self.removeOrphansOffMain(in: folder, eligibleStems: eligible)
                }.value
            deleted = removalResult.deleted
            errors.append(contentsOf: removalResult.errors)
            progress.deletedSoFar = deleted
            perDestination[dest.id] = .running(progress)
        }

        let summary = Summary(
            copied: progress.copied,
            skipped: progress.skipped,
            deleted: deleted,
            errors: errors,
            elapsed: Date().timeIntervalSince(progress.startedAt)
        )
        if token.isCancelled {
            perDestination[dest.id] = .cancelled(summary)
        } else if !errors.isEmpty && progress.copied == 0 {
            perDestination[dest.id] = .failed("All copies failed", summary)
        } else {
            perDestination[dest.id] = .done(summary)
        }
        return summary
    }

    // MARK: - Shared-read run (Mode B)

    /// One read per source file, fanned out as writes to every destination
    /// that wants this file AND whose overwrite decision says `.write`.
    /// Skips and orphan removal are accounted for per destination
    /// individually, exactly the same way Mode A would have done them.
    /// Result is byte-identical to running Mode A over the same destinations.
    private func runAllSharedRead(
        pairs: [PhotoPair],
        pairXMPs: [String: XMPSidecar],
        projectName: String,
        destinations: [ExportSettings.Destination]
    ) async -> [(ExportSettings.Destination, Summary)] {
        // Per-destination scratch state.
        struct DestState {
            let dest: ExportSettings.Destination
            let plan: ExportPlanner.Plan
            var progress: Progress
            var errors: [Summary.ErrorEntry]
            var token: CancellationToken
        }
        var states: [UUID: DestState] = [:]
        for dest in destinations {
            let plan = ExportPlanner.plan(
                pairs: pairs, pairXMPs: pairXMPs,
                projectName: projectName, destination: dest
            )
            let progress = Progress(
                copied: 0, skipped: 0, deletedSoFar: 0,
                total: plan.fileOperations.count,
                bytesCopied: 0, totalBytes: plan.totalBytes,
                currentFilename: nil, startedAt: Date()
            )
            states[dest.id] = DestState(
                dest: dest, plan: plan, progress: progress,
                errors: [], token: cancellationTokens[dest.id] ?? CancellationToken()
            )
            perDestination[dest.id] = .running(progress)
        }

        // mkdir -p every outputFolder off-main upfront. On SMB shares each
        // createDirectory call can take a noticeable moment; doing them all
        // synchronously on MainActor would stall the UI before any copy.
        let folders = destinations.map { $0 }.compactMap { d -> URL? in
            states[d.id]?.plan.outputFolder
        }
        _ = await Task.detached(priority: .userInitiated) {
            for folder in folders {
                try? FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
            }
        }.value

        // Group operations by source URL. For each source, build a list of
        // (destID, destURL, isXMP, policy) wanting writes for THAT source.
        struct ReadRequest: @unchecked Sendable {
            let sourceURL: URL
            let isXMP: Bool
            var writes: [(destID: UUID, destURL: URL, policy: ExportSettings.OverwritePolicy)]
        }
        var requestsBySource: [URL: ReadRequest] = [:]
        for (destID, state) in states {
            for op in state.plan.fileOperations {
                if requestsBySource[op.sourceURL] == nil {
                    requestsBySource[op.sourceURL] = ReadRequest(
                        sourceURL: op.sourceURL, isXMP: op.isXMP, writes: []
                    )
                }
                requestsBySource[op.sourceURL]?.writes.append(
                    (destID, op.destinationURL, state.dest.overwrite)
                )
            }
        }

        // Per-source: detached task does the stat + decide + read + writes.
        // Returns the per-destination outcomes which we apply back on main.
        enum WriteOutcome: Sendable {
            case skip(destID: UUID)
            case copied(destID: UUID, bytes: Int64)
            case errored(destID: UUID, message: String)
        }
        struct SourceResult: Sendable {
            let sourceFilename: String
            let outcomes: [WriteOutcome]
        }

        for (_, request) in requestsBySource {
            if states.values.allSatisfy({ $0.token.isCancelled }) { break }
            // Snapshot tokens off-thread access: copy the cancelled flag for
            // each destination at start of this file.
            let cancelledForDest: [UUID: Bool] = Dictionary(uniqueKeysWithValues:
                request.writes.map { ($0.destID, states[$0.destID]?.token.isCancelled ?? true) }
            )

            let result: SourceResult = await Task.detached(priority: .userInitiated) {
                let srcSnap = FileSystemSnapshot.snap(request.sourceURL)
                var outcomes: [WriteOutcome] = []
                // First pass: decide.
                var writePlan: [(destID: UUID, destURL: URL, removeFirst: Bool, size: Int64)] = []
                for write in request.writes {
                    if cancelledForDest[write.destID] == true { continue }
                    let dstSnap = FileSystemSnapshot.snap(write.destURL)
                    let decision = OverwriteDecision.decide(
                        source: srcSnap, destination: dstSnap,
                        isXMP: request.isXMP, policy: write.policy
                    )
                    switch decision {
                    case .skip:
                        outcomes.append(.skip(destID: write.destID))
                    case .write(let removeFirst):
                        writePlan.append((write.destID, write.destURL, removeFirst, srcSnap.size ?? 0))
                    }
                }

                // No reader if nothing wants a write.
                guard !writePlan.isEmpty else {
                    return SourceResult(sourceFilename: request.sourceURL.lastPathComponent,
                                        outcomes: outcomes)
                }

                // Single read.
                let data: Data
                do {
                    data = try Data(contentsOf: request.sourceURL)
                } catch {
                    for w in writePlan {
                        outcomes.append(.errored(destID: w.destID,
                                                 message: "read failed: \(error.localizedDescription)"))
                    }
                    return SourceResult(sourceFilename: request.sourceURL.lastPathComponent,
                                        outcomes: outcomes)
                }

                for w in writePlan {
                    do {
                        // .atomic does the temp-file + rename swap itself,
                        // overwriting an existing dest in a single inode flip.
                        // We intentionally do NOT removeItem first — that
                        // would leave a small window where dest is missing.
                        _ = w.removeFirst   // intentionally unused
                        try data.write(to: w.destURL, options: .atomic)
                        outcomes.append(.copied(destID: w.destID, bytes: w.size))
                    } catch {
                        outcomes.append(.errored(destID: w.destID,
                                                 message: error.localizedDescription))
                    }
                }
                return SourceResult(sourceFilename: request.sourceURL.lastPathComponent,
                                    outcomes: outcomes)
            }.value

            // Apply on main actor.
            for outcome in result.outcomes {
                switch outcome {
                case .skip(let destID):
                    if var state = states[destID] {
                        state.progress.skipped += 1
                        state.progress.currentFilename = result.sourceFilename
                        states[destID] = state
                        perDestination[destID] = .running(state.progress)
                        bumpBatch(filesDelta: 1, bytesDelta: 0)
                    }
                case .copied(let destID, let bytes):
                    if var state = states[destID] {
                        state.progress.copied += 1
                        state.progress.bytesCopied += bytes
                        state.progress.currentFilename = result.sourceFilename
                        states[destID] = state
                        perDestination[destID] = .running(state.progress)
                        bumpBatch(filesDelta: 1, bytesDelta: bytes)
                    }
                case .errored(let destID, let msg):
                    if var state = states[destID] {
                        state.errors.append(.init(
                            file: result.sourceFilename, message: msg))
                        states[destID] = state
                    }
                }
            }
        }

        // Per-destination orphan-removal phase (cannot be batched — orphans
        // depend on each destination's eligible-stems set). Off-main.
        var summaries: [(ExportSettings.Destination, Summary)] = []
        for dest in destinations {
            guard var state = states[dest.id] else { continue }
            var deleted = 0
            if !state.token.isCancelled, dest.removeOrphans {
                let eligible = state.plan.eligibleStems
                let folder = state.plan.outputFolder
                let removalResult: (deleted: Int, errors: [Summary.ErrorEntry]) =
                    await Task.detached(priority: .userInitiated) {
                        Self.removeOrphansOffMain(in: folder, eligibleStems: eligible)
                    }.value
                deleted = removalResult.deleted
                state.errors.append(contentsOf: removalResult.errors)
                state.progress.deletedSoFar = deleted
            }

            let summary = Summary(
                copied: state.progress.copied,
                skipped: state.progress.skipped,
                deleted: deleted,
                errors: state.errors,
                elapsed: Date().timeIntervalSince(state.progress.startedAt)
            )
            if state.token.isCancelled {
                perDestination[dest.id] = .cancelled(summary)
            } else if !state.errors.isEmpty && state.progress.copied == 0 {
                perDestination[dest.id] = .failed("All copies failed", summary)
            } else {
                perDestination[dest.id] = .done(summary)
            }
            summaries.append((dest, summary))
        }
        return summaries
    }

    /// Per-file outcome from the off-main copy task (used by Mode A loop).
    private enum FileOutcome: Sendable {
        case skipped
        case copied(bytes: Int64)
        case errored(String)
    }

    /// Increment the running batchProgress (no-op if none is active).
    private func bumpBatch(filesDelta: Int, bytesDelta: Int64) {
        guard var batch = batchProgress else { return }
        batch.filesDone += filesDelta
        batch.bytesCopied += bytesDelta
        batchProgress = batch
    }

    /// Atomic copy. Writes the source to a sibling `.tmp` file in the
    /// destination directory and then swaps it in via either
    /// `FileManager.replaceItemAt` (when dest exists) or `moveItem` (when
    /// it doesn't). At no point does a partially-written file live at
    /// `destURL` — the user always sees either the old file or the
    /// complete new one, never a half-copy.
    ///
    /// Cleanup: if the temp copy succeeds but the swap fails, the temp
    /// file is removed before throwing so we don't leak partial files.
    /// If the temp copy itself fails (cancel, disk full, read error),
    /// the temp file may or may not exist depending on how far copyItem
    /// got; we attempt cleanup defensively.
    nonisolated static func atomicCopy(
        from src: URL, to dest: URL, destExists: Bool
    ) throws {
        let fm = FileManager.default
        let tmp = dest
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(dest.lastPathComponent).photox-\(UUID().uuidString.prefix(8)).tmp"
            )
        do {
            try fm.copyItem(at: src, to: tmp)
        } catch {
            try? fm.removeItem(at: tmp)  // copyItem may have left a partial
            throw error
        }
        do {
            if destExists {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Off-main static version of orphan removal. Returns the count + any
    /// errors so caller can apply them under MainActor.
    nonisolated static func removeOrphansOffMain(
        in folder: URL, eligibleStems: Set<String>
    ) -> (deleted: Int, errors: [Summary.ErrorEntry]) {
        let managedExtensions: Set<String> = ["arw", "hif", "heif", "heic", "xmp"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return (0, []) }
        var count = 0
        var errors: [Summary.ErrorEntry] = []
        for url in contents {
            let ext = url.pathExtension.lowercased()
            guard managedExtensions.contains(ext) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard !eligibleStems.contains(stem) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                count += 1
            } catch {
                errors.append(.init(file: url.lastPathComponent,
                                    message: "delete failed: \(error.localizedDescription)"))
            }
        }
        return (count, errors)
    }
}

extension ExportRunner.Summary {
    static let empty = ExportRunner.Summary(copied: 0, skipped: 0, deleted: 0,
                                            errors: [], elapsed: 0)
}

// MARK: - File system snapshot helper

enum FileSystemSnapshot {
    static func snap(_ url: URL) -> FileSnapshot {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        guard let size = attrs[.size] as? Int64 ?? (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else {
            return .missing
        }
        return FileSnapshot(size: size, mtime: mtime)
    }
}

// MARK: - Notifications adapter (injection point for tests)

/// Tiny seam so tests can substitute a recording adapter for the real
/// UNUserNotificationCenter calls. Concrete implementation lives in
/// `ExportNotifications.swift`.
struct ExportNotificationsAdapter: Sendable {
    var postDestinationComplete: @Sendable (ExportSettings.Destination, ExportRunner.Summary) -> Void
    var postAllComplete: @Sendable ([(ExportSettings.Destination, ExportRunner.Summary)]) -> Void

    static let live = ExportNotificationsAdapter(
        postDestinationComplete: { dest, summary in
            Task { @MainActor in
                ExportNotifications.postDestinationComplete(dest: dest, summary: summary)
            }
        },
        postAllComplete: { summaries in
            Task { @MainActor in
                ExportNotifications.postAllComplete(summaries: summaries)
            }
        }
    )

    /// No-op adapter used by tests that don't care about notifications.
    static let silent = ExportNotificationsAdapter(
        postDestinationComplete: { _, _ in },
        postAllComplete: { _ in }
    )
}
