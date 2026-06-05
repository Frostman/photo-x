import Foundation
import Observation

/// The in-flight engine that does the actual file copies for the Export
/// feature. Owned per-window by `ViewerState` so two open shoots can
/// run independent export batches with their own progress, per-
/// destination state, and toolbar pill. Per-window state survives the
/// sheet being closed (user can switch tabs while a batch runs).
///
/// `ExportRunner` deliberately doesn't own a `ViewerState` or `Shoot` —
/// callers pass `entries` + `entryXMPs` BY VALUE at start, so the run is
/// independent of subsequent navigation / shoot close.
@MainActor
@Observable
final class ExportRunner {

    /// Notified each time a destination finishes a run cleanly
    /// (.done — NOT .cancelled or .failed). ViewerState wires this
    /// at startup to feed UsageMetrics so the stats window can show
    /// lifetime exports + images-exported counters. One callback
    /// per destination per batch: a 3-destination batch fires 3
    /// times. Off-spec a-priori (a batch is one user action), but
    /// matches what the per-destination success state actually means.
    var onDestinationCompleted: (@MainActor (Summary) -> Void)?

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

    /// Owns the planning phase's per-task progress trackers
    /// (source + per-destination). Non-nil while planning is
    /// in flight; cleared the same MainActor tick that
    /// `batchProgress` is populated so the UI transitions
    /// from "Planning…" to copy-progress without an idle
    /// frame.
    private(set) var planningProgress: PlanningPhaseProgress?

    /// Outcome of the most recently completed batch. Drives the pill's
    /// post-run label ("Export: done" / "Export: cancelled" with "Nm ago").
    /// Not persisted across launches.
    enum BatchOutcome: Sendable, Hashable {
        case done       // every destination finished cleanly
        case cancelled  // at least one destination was cancelled
        case failed     // at least one destination failed (and none cancelled)
    }
    private(set) var lastBatchOutcome: BatchOutcome?
    private(set) var lastBatchCompletedAt: Date?

    /// When each destination reached a terminal state (done / cancelled /
    /// failed). Used to render the "Nm ago" label on each row. Cleared at
    /// the start of the next batch.
    private(set) var perDestinationCompletedAt: [UUID: Date] = [:]

    /// Monotonic generation counter bumped on every `resetState` and on
    /// every `startAll` / `startOne`. The force-reset path uses it to
    /// schedule a *deferred* second clear: after `waitForCompletion()`,
    /// any in-flight task's late writes (cancellation outcome, final
    /// `lastBatchOutcome`, etc.) have landed — at that point we re-clear,
    /// but only if the epoch is still ours (no new export has started in
    /// the meantime). Without this, cancel-and-close-shoot leaves stale
    /// "Export: cancelled Nm ago" text on the toolbar tab for the next
    /// shoot.
    private var stateEpoch: Int = 0

    struct BatchProgress: Sendable, Hashable {
        var filesDone: Int        // copied + skipped across all dests
        var filesTotal: Int
        var bytesCopied: Int64
        var bytesTotal: Int64
        var startedAt: Date

        /// Number of destinations in this batch (1 for per-row Run).
        var destinationCount: Int = 1
        /// 1-based index of the destination currently being processed.
        /// Only meaningful for the sequential (Mode A) path; nil for the
        /// shared-read (Mode B) path because all destinations advance in
        /// lockstep there.
        var currentDestinationIndex: Int?

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

    /// Wipe all per-destination + batch state so the toolbar pill
    /// and the Export sheet go back to "no export ever ran" until
    /// the next Run / Export-all. Called by `ViewerState.closeShoot`
    /// so the starter screen isn't haunted by the previous shoot's
    /// export outcome.
    ///
    /// No-op while an export is in flight — the caller is expected
    /// to cancel first (see `ContentView.closeShootGuarded`).
    /// Pass `force: true` to clear regardless of in-flight state;
    /// the close-shoot path uses this because cancellation is
    /// asynchronous and the runner can still report `isRunning`
    /// when we arrive here, leaving stale per-destination UI on
    /// the next shoot.
    func resetState(force: Bool = false) {
        if !force {
            guard !isRunning && !hasQueued else { return }
        }
        clearAllState()
        if force {
            // Bump the epoch and schedule a deferred re-clear once
            // all currently-running tasks have wound down — they
            // may still write back cancellation / final-outcome
            // state after this synchronous clear. The deferred
            // clear is abandoned if a new export starts before it
            // fires (startAll / startOne also bump the epoch).
            stateEpoch &+= 1
            let myEpoch = stateEpoch
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitForCompletion()
                guard self.stateEpoch == myEpoch else { return }
                self.clearAllState()
            }
        }
    }

    private func clearAllState() {
        perDestination.removeAll()
        perDestinationCompletedAt.removeAll()
        batchProgress = nil
        lastBatchOutcome = nil
        lastBatchCompletedAt = nil
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

    /// Foundation activity token that suppresses idle-system-sleep while a
    /// batch is in flight. Acquired in startAll/startOne, released when the
    /// batch finishes (clean exit, cancellation, or failure). On crash /
    /// kill -9 / force-quit, powerd drops the underlying IOPMAssertion
    /// automatically when our PID exits — no dangling state possible.
    private var sleepAssertion: NSObjectProtocol?

    /// Exposed for tests + diagnostics. True while we're actively asking
    /// macOS to suppress idle sleep on behalf of an export.
    var isPreventingSleep: Bool { sleepAssertion != nil }

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
        entries: [PhotoEntry],
        entryXMPs: [String: XMPSidecar],
        projectName: String,
        destinations: [ExportSettings.Destination],
        sharedRead: Bool = false,
        notifications: ExportNotificationsAdapter = .live
    ) {
        guard !destinations.isEmpty else { return }
        // New session — bump epoch so any pending deferred reset
        // (from a prior force-reset awaiting waitForCompletion)
        // is abandoned and doesn't clear our fresh state.
        stateEpoch &+= 1
        // Clear stale post-completion state for these destinations + the
        // last batch — a new run shouldn't display "5m ago" alongside its
        // own in-flight progress.
        lastBatchOutcome = nil
        lastBatchCompletedAt = nil
        for dest in destinations {
            perDestination[dest.id] = .queued
            cancellationTokens[dest.id] = CancellationToken()
            perDestinationCompletedAt.removeValue(forKey: dest.id)
        }
        // Acquire the idle-sleep assertion synchronously so any observer
        // (UI / tests) sees `isPreventingSleep == true` the moment this
        // method returns. If we deferred this into the Task body, there'd
        // be a window where the user clicked Export, the run is queued,
        // but the assertion hasn't been taken yet.
        beginPreventingSleep(destinationCount: destinations.count)
        // Publish the planning-progress trackers on the
        // MainActor BEFORE the task spawns so any UI bound
        // to `runner.planningProgress` redraws immediately —
        // no idle frame between the click and the first
        // "Planning…" indicator.
        let planning = PlanningPhaseProgress()
        planningProgress = planning

        let task = Task { [weak self] in
            guard let self else { return }
            // Phase 1: parallel planning. Source-side stat
            // sweep + per-destination readdir in one
            // TaskGroup; reports per-card progress. Blocks
            // destinations whose project subfolder is
            // non-empty when their per-row "Allow
            // non-empty" toggle is off.
            let planResult = await ExportPlanner.runPlanningPhase(
                entries: entries,
                projectName: projectName,
                destinations: destinations,
                progress: planning
            )

            // Mark blocked destinations failed immediately;
            // they're skipped from the copy phase. Other
            // destinations proceed.
            var runnable: [ExportSettings.Destination] = []
            for dest in destinations {
                if let reason = planResult.perDestination[dest.id]?.blockedReason {
                    self.perDestination[dest.id] = .failed(reason, nil)
                    self.perDestinationCompletedAt[dest.id] = Date()
                } else {
                    runnable.append(dest)
                }
            }

            // No runnable destinations → wrap up batch with
            // the failed outcome path. Mirrors the normal
            // batch-end book-keeping so the UI's
            // post-completion label / cleanup all happen.
            guard !runnable.isEmpty else {
                let summaries: [(ExportSettings.Destination, Summary)] = destinations.map { ($0, .empty) }
                self.planningProgress = nil
                notifications.postAllComplete(summaries)
                self.endPreventingSleep()
                let outcome = self.summariseBatchOutcome(for: destinations)
                self.lastBatchOutcome = outcome
                self.lastBatchCompletedAt = Date()
                self.logBatchCompletion(summaries: summaries,
                                        outcome: outcome,
                                        startedAt: Date())
                return
            }

            // Phase 2: build per-destination plans from the
            // cached source sizes. No additional stats —
            // every byte count comes from the planning
            // phase's map.
            let plans: [ExportPlanner.Plan] = await Task.detached(priority: .userInitiated) { [planResult, runnable] in
                runnable.map { dest in
                    ExportPlanner.plan(entries: entries, entryXMPs: entryXMPs,
                                       projectName: projectName, destination: dest,
                                       sourceSizes: planResult.sourceSizes)
                }
            }.value
            let totalFiles = plans.reduce(0) { $0 + $1.fileOperations.count }
            let totalBytes = plans.reduce(Int64(0)) { $0 + $1.totalBytes }
            // Atomic swap: clear planningProgress and set
            // batchProgress in the same MainActor tick so
            // the per-card UI transitions from planning bar
            // to copy bar with no idle frame.
            self.planningProgress = nil
            self.batchProgress = BatchProgress(
                filesDone: 0, filesTotal: totalFiles,
                bytesCopied: 0, bytesTotal: totalBytes,
                startedAt: Date(),
                destinationCount: runnable.count,
                // Mode A starts on destination 1; Mode B leaves this nil
                // because all destinations interleave per source file.
                currentDestinationIndex: sharedRead ? nil : 1
            )

            let summaries: [(ExportSettings.Destination, Summary)]
            if sharedRead {
                summaries = await self.runAllSharedRead(
                    entries: entries, entryXMPs: entryXMPs,
                    projectName: projectName, destinations: runnable
                )
            } else {
                summaries = await self.runAllSequential(
                    entries: entries, entryXMPs: entryXMPs,
                    projectName: projectName, destinations: runnable
                )
            }
            // Include blocked destinations in the
            // notification + outcome roll-up so the post-run
            // pill / log reflects that something failed.
            var allSummaries = summaries
            for dest in destinations where !runnable.contains(where: { $0.id == dest.id }) {
                allSummaries.append((dest, .empty))
            }
            notifications.postAllComplete(allSummaries)
            let startedAt = self.batchProgress?.startedAt ?? Date()
            self.batchProgress = nil
            self.endPreventingSleep()
            let outcome = self.summariseBatchOutcome(for: destinations)
            self.lastBatchOutcome = outcome
            self.lastBatchCompletedAt = Date()
            self.logBatchCompletion(summaries: allSummaries,
                                    outcome: outcome,
                                    startedAt: startedAt)
        }
        runningTasks[Self.batchSentinelID] = task
    }

    private func runAllSequential(
        entries: [PhotoEntry],
        entryXMPs: [String: XMPSidecar],
        projectName: String,
        destinations: [ExportSettings.Destination]
    ) async -> [(ExportSettings.Destination, Summary)] {
        var summaries: [(ExportSettings.Destination, Summary)] = []
        for (idx, dest) in destinations.enumerated() {
            if cancellationTokens[dest.id]?.isCancelled == true {
                perDestination[dest.id] = .cancelled(.empty)
                perDestinationCompletedAt[dest.id] = Date()
                continue
            }
            // Reflect "destination N of M" in the toolbar pill.
            if var batch = batchProgress {
                batch.currentDestinationIndex = idx + 1
                batchProgress = batch
            }
            let summary = await self.runSingle(
                destination: dest, entries: entries, entryXMPs: entryXMPs,
                projectName: projectName
            )
            summaries.append((dest, summary))
        }
        return summaries
    }

    /// Run a single destination. Posts one completion notification.
    func startOne(
        _ destinationID: UUID,
        entries: [PhotoEntry],
        entryXMPs: [String: XMPSidecar],
        projectName: String,
        destination: ExportSettings.Destination,
        notifications: ExportNotificationsAdapter = .live
    ) {
        // See note in startAll: bump epoch so any pending
        // deferred reset abandons.
        stateEpoch &+= 1
        lastBatchOutcome = nil
        lastBatchCompletedAt = nil
        perDestinationCompletedAt.removeValue(forKey: destinationID)
        perDestination[destinationID] = .queued
        cancellationTokens[destinationID] = CancellationToken()
        beginPreventingSleep(destinationCount: 1)

        // Same planning-phase publishing pattern as
        // startAll — emit the trackers before the Task
        // spawns so the row's progress bar appears
        // immediately.
        let planning = PlanningPhaseProgress()
        planningProgress = planning

        let task = Task { [weak self] in
            guard let self else { return }
            // Phase 1: planning. Same TaskGroup machinery
            // as Export-all, just one destination.
            let planResult = await ExportPlanner.runPlanningPhase(
                entries: entries,
                projectName: projectName,
                destinations: [destination],
                progress: planning
            )

            // Blocked → fail this destination, end the
            // "batch" of one.
            if let reason = planResult.perDestination[destination.id]?.blockedReason {
                self.perDestination[destination.id] = .failed(reason, nil)
                self.perDestinationCompletedAt[destination.id] = Date()
                self.planningProgress = nil
                notifications.postAllComplete([(destination, .empty)])
                self.endPreventingSleep()
                let outcome = self.summariseBatchOutcome(for: [destination])
                self.lastBatchOutcome = outcome
                self.lastBatchCompletedAt = Date()
                self.logBatchCompletion(summaries: [(destination, .empty)],
                                        outcome: outcome,
                                        startedAt: Date())
                return
            }

            // Phase 2: build the plan from the cached
            // source sizes — no extra stats.
            let plan: ExportPlanner.Plan = await Task.detached(priority: .userInitiated) { [planResult] in
                ExportPlanner.plan(entries: entries, entryXMPs: entryXMPs,
                                   projectName: projectName, destination: destination,
                                   sourceSizes: planResult.sourceSizes)
            }.value
            self.planningProgress = nil
            self.batchProgress = BatchProgress(
                filesDone: 0, filesTotal: plan.fileOperations.count,
                bytesCopied: 0, bytesTotal: plan.totalBytes,
                startedAt: Date()
            )
            let summary = await self.runSingle(
                destination: destination, entries: entries, entryXMPs: entryXMPs,
                projectName: projectName
            )
            // Single-destination Run uses the same one-summary notification
            // as Export-all (just a batch of one).
            notifications.postAllComplete([(destination, summary)])
            let startedAt = self.batchProgress?.startedAt ?? Date()
            self.batchProgress = nil
            self.endPreventingSleep()
            let outcome = self.summariseBatchOutcome(for: [destination])
            self.lastBatchOutcome = outcome
            self.lastBatchCompletedAt = Date()
            self.logBatchCompletion(summaries: [(destination, summary)],
                                    outcome: outcome,
                                    startedAt: startedAt)
        }
        runningTasks[destinationID] = task
    }

    /// One production summary line per export batch. Stats answer the
    /// only useful post-hoc questions: outcome, how many destinations,
    /// how many files copied / skipped / deleted, how many errors, total
    /// wall time.
    private func logBatchCompletion(
        summaries: [(ExportSettings.Destination, Summary)],
        outcome: BatchOutcome,
        startedAt: Date
    ) {
        let copied  = summaries.reduce(0) { $0 + $1.1.copied }
        let skipped = summaries.reduce(0) { $0 + $1.1.skipped }
        let deleted = summaries.reduce(0) { $0 + $1.1.deleted }
        let errors  = summaries.reduce(0) { $0 + $1.1.errors.count }
        let elapsed = Date().timeIntervalSince(startedAt)
        let word: String = switch outcome {
        case .done:      "complete"
        case .cancelled: "cancelled"
        case .failed:    "failed"
        }
        Log.app.notice("Export \(word, privacy: .public): \(summaries.count, privacy: .public) destinations, \(copied, privacy: .public) copied, \(skipped, privacy: .public) skipped, \(deleted, privacy: .public) deleted, \(errors, privacy: .public) errors, \(formattedDuration(elapsed), privacy: .public)")

        // Notify the XCUITest side that a batch has finished. The
        // helper writes the outcome string to a payload file and
        // posts the `exportCompleted` Darwin notification. It's a
        // no-op outside `-photoxUITestMode YES` launches — see
        // `UITestResetObserver.postExportCompleted`.
        UITestResetObserver.postExportCompleted(outcome: word)
    }

    /// Inspect `perDestination` for the destinations in this batch and roll
    /// up to a single outcome.
    private func summariseBatchOutcome(
        for destinations: [ExportSettings.Destination]
    ) -> BatchOutcome {
        var anyCancelled = false
        var anyFailed = false
        for dest in destinations {
            switch perDestination[dest.id] {
            case .cancelled: anyCancelled = true
            case .failed:    anyFailed = true
            default: break
            }
        }
        if anyCancelled { return .cancelled }
        if anyFailed    { return .failed }
        return .done
    }

    /// Flip every per-destination cancellation token. The runner's per-file
    /// loop checks the token between files and bails. The sleep assertion
    /// is released by the spawned Task once it winds down — typically within
    /// a fraction of a second, but at most one full file-copy duration
    /// (we let any in-flight copyItem finish so we don't leave a partial
    /// file at the destination from a half-completed write).
    func cancelAll() {
        for token in cancellationTokens.values { token.cancel() }
    }

    /// Same semantics as cancelAll() but scoped to a single destination.
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
        entries: [PhotoEntry],
        entryXMPs: [String: XMPSidecar],
        projectName: String
    ) async -> Summary {
        let token = cancellationTokens[dest.id] ?? CancellationToken()
        let plan = ExportPlanner.plan(
            entries: entries, entryXMPs: entryXMPs,
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
            perDestinationCompletedAt[dest.id] = Date()
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
        } else if !errors.isEmpty {
            // Any per-file error promotes the whole destination to .failed
            // so the pill + row colour the run red rather than green. Some
            // files may have copied successfully; their counts stay in the
            // summary for the user to see what got through.
            let detail = errors.count == 1 ? "1 file failed" : "\(errors.count) files failed"
            perDestination[dest.id] = .failed(detail, summary)
        } else {
            perDestination[dest.id] = .done(summary)
            onDestinationCompleted?(summary)
        }
        perDestinationCompletedAt[dest.id] = Date()
        return summary
    }

    // MARK: - Shared-read run (Mode B)

    /// One read per source file, fanned out as writes to every destination
    /// that wants this file AND whose overwrite decision says `.write`.
    /// Skips and orphan removal are accounted for per destination
    /// individually, exactly the same way Mode A would have done them.
    /// Result is byte-identical to running Mode A over the same destinations.
    private func runAllSharedRead(
        entries: [PhotoEntry],
        entryXMPs: [String: XMPSidecar],
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
                entries: entries, entryXMPs: entryXMPs,
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
                        // Data.write sets mtime to "now". Without this stamp
                        // the next run sees a mtime delta of however long
                        // the export took, defeating the universal skip
                        // rule. We must propagate the source's mtime.
                        if let srcMtime = srcSnap.mtime {
                            try? FileManager.default.setAttributes(
                                [.modificationDate: srcMtime],
                                ofItemAtPath: w.destURL.path
                            )
                        }
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
            } else if !state.errors.isEmpty {
                let detail = state.errors.count == 1
                    ? "1 file failed" : "\(state.errors.count) files failed"
                perDestination[dest.id] = .failed(detail, summary)
            } else {
                perDestination[dest.id] = .done(summary)
                onDestinationCompleted?(summary)
            }
            perDestinationCompletedAt[dest.id] = Date()
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

    /// Acquire macOS's idle-sleep suppression for the duration of a batch.
    /// Idempotent — repeated calls (e.g. nested startOne while startAll is
    /// active) are a no-op. The reason string surfaces in
    /// `pmset -g assertions` so the user can audit who's keeping the
    /// machine awake.
    private func beginPreventingSleep(destinationCount: Int) {
        guard sleepAssertion == nil else { return }
        let suffix = destinationCount == 1 ? "" : "s"
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "PhotoX is exporting to \(destinationCount) destination\(suffix)"
        )
    }

    /// Release the idle-sleep suppression. Idempotent — safe to call when
    /// no assertion is held. `powerd` would clean up at process exit
    /// anyway; this is just the polite path.
    private func endPreventingSleep() {
        guard let token = sleepAssertion else { return }
        ProcessInfo.processInfo.endActivity(token)
        sleepAssertion = nil
    }

    /// Increment the running batchProgress (no-op if none is active).
    private func bumpBatch(filesDelta: Int, bytesDelta: Int64) {
        guard var batch = batchProgress else { return }
        batch.filesDone += filesDelta
        batch.bytesCopied += bytesDelta
        batchProgress = batch
    }

    /// One stat per source file (ARW + preview + xmp-if-exists) — shared
    /// across every destination's `ExportPlanner.plan(…)` call via the
    /// `sourceSizes` parameter. Replaces the previous per-destination
    /// stat sweep, which on slow source media (SD / CFExpress) added a
    /// multi-second pre-flight delay scaling with destination count.
    ///
    /// Maps absent XMP sidecars to a missing key (not `0`) so the
    /// planner can treat "key present" as proof-of-existence and skip
    /// its own redundant `fileExists` check on the same path.
    nonisolated static func precomputeSourceSizes(
        entries: [PhotoEntry]
    ) -> [URL: Int64] {
        var out: [URL: Int64] = [:]
        let fm = FileManager.default
        for entry in entries {
            if let raw = entry.rawURL { out[raw] = sizeOf(raw, fm: fm) }
            out[entry.previewURL] = sizeOf(entry.previewURL, fm: fm)
            let xmp = entry.xmpURL
            if fm.fileExists(atPath: xmp.path) {
                out[xmp] = sizeOf(xmp, fm: fm)
            }
        }
        return out
    }

    nonisolated private static func sizeOf(_ url: URL, fm: FileManager) -> Int64 {
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        if let n = attrs[.size] as? Int64 { return n }
        if let n = (attrs[.size] as? NSNumber)?.int64Value { return n }
        return 0
    }

    /// Atomic copy. Writes the source to a sibling `.tmp` file in the
    /// destination directory and then swaps it in via either
    /// `FileManager.replaceItemAt` (when dest exists) or `moveItem` (when
    /// it doesn't). At no point does a partially-written file live at
    /// `destURL` — the user always sees either the old file or the
    /// complete new one, never a half-copy.
    ///
    /// After the swap we explicitly re-stamp the destination's mtime to
    /// match the source. `copyItem` is documented to preserve attributes,
    /// but SMB / some FUSE mounts don't honour that across rename. Without
    /// this, the next run sees dest.mtime as "now" and the universal
    /// skip-if-same-size-and-mtime check fails, so unchanged files get
    /// pointlessly recopied.
    ///
    /// Cleanup: if any step fails, the temp file is removed before throwing
    /// so we don't leak partials.
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
            try? fm.removeItem(at: tmp)
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
        // Best-effort mtime preservation. Failure (e.g. read-only mount) is
        // logged silently and not propagated — the file still copied.
        if let srcAttrs = try? fm.attributesOfItem(atPath: src.path),
           let srcMtime = srcAttrs[.modificationDate] as? Date {
            try? fm.setAttributes([.modificationDate: srcMtime],
                                  ofItemAtPath: dest.path)
        }
    }

    /// Off-main static version of orphan removal. Returns the count + any
    /// errors so caller can apply them under MainActor.
    nonisolated static func removeOrphansOffMain(
        in folder: URL, eligibleStems: Set<String>
    ) -> (deleted: Int, errors: [Summary.ErrorEntry]) {
        let managedExtensions: Set<String> = ["arw", "hif", "heif", "heic", "jpg", "jpeg", "xmp"]
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
/// `ExportNotifications.swift`. Only one notification fires per batch —
/// per-destination notifications were removed (noisy + duplicative
/// with the per-row progress in the sheet).
struct ExportNotificationsAdapter: Sendable {
    var postAllComplete: @Sendable ([(ExportSettings.Destination, ExportRunner.Summary)]) -> Void

    static let live = ExportNotificationsAdapter(
        postAllComplete: { summaries in
            Task { @MainActor in
                ExportNotifications.postAllComplete(summaries: summaries)
            }
        }
    )

    /// No-op adapter used by tests that don't care about notifications.
    static let silent = ExportNotificationsAdapter(postAllComplete: { _ in })
}
