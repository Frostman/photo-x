import Foundation

/// All XMP sidecar writes flow through this actor. Three responsibilities:
///
/// 1. **Per-stem serialization** — two writes to the same `.xmp`
///    file must never race. Each stem has its own dedicated chain;
///    cross-stem writes run concurrently.
///
/// 2. **Latest-intent coalescing per stem** — rapid `1,2,3,4,5`
///    keypresses don't queue five disk writes; only the latest
///    `rating` lands. Same for label. Rating and label are
///    independent fields, so changing both converges to one disk
///    write whenever the second call lands before the first task
///    has taken its snapshot. The currently-running write completes
///    normally; new intent arriving during the run is picked up by
///    the loop's next iteration.
///
/// 3. **Retry on transient failure** — each attempt of the disk
///    write is retried `backoff.count` times. If every attempt
///    fails, a `FailedWrite` carrying the *intent* (not just a
///    single field) is emitted on `failureStream` so the UI can
///    show what we tried — `★5` / label chip — and offer Retry.
///
/// Plus a per-stem **bytes cache** so consecutive writes skip the
/// disk read: on success we remember `(serializedXMP, mtime)` and
/// on the next write reuse those bytes as the base instead of
/// re-reading the file. If the on-disk mtime drifted (Lightroom
/// running in the background, etc.), the cache is bypassed and the
/// file is re-read — see `XMPSidecarWriter.applyIntent`.
///
/// **Why this matters**: saving culling decisions is the project's
/// single most important promise (see project memory
/// `project_xmp_write_reliability.md`). Every XMP write in the app
/// should go through this coordinator — never directly call
/// `XMPSidecarWriter.update…` from a fire-and-forget `Task`.
actor XMPWriteCoordinator {
    /// Kept as the `enqueueWork` test API's label for the failure
    /// it would emit if the closure exhausted retries. Real prod
    /// writes go through `writeRating` / `writeLabel` / `writeIntent`,
    /// which build `SidecarIntent` directly.
    enum WriteKind: Sendable, Equatable {
        case rating(Int?)
        case label(String?)

        var description: String {
            switch self {
            case .rating(nil):       return "clear rating"
            case .rating(let r?):    return "rating=\(r)"
            case .label(nil):        return "clear label"
            case .label(let l?):     return "label=\(l)"
            }
        }

        var asIntent: SidecarIntent {
            switch self {
            case .rating(let r): return .setRating(r)
            case .label(let l):  return .setLabel(l)
            }
        }
    }

    struct FailedWrite: Sendable, Equatable {
        let stem: String
        /// What we tried to write this round. Carries every field the
        /// coalesced write was going to touch — so retry can resync
        /// the whole sidecar from the user's in-memory intent.
        var intent: SidecarIntent
        let attempts: Int
        let lastError: String
        let timestamp: Date

        /// Merge a newer failure for the same stem into self. The
        /// newer one's metadata (attempts/error/timestamp) replaces
        /// the older; intents combine (other's set fields win) so
        /// a rating-then-label failure preserves both.
        func merged(with newer: FailedWrite) -> FailedWrite {
            var mergedIntent = intent
            mergedIntent.merge(newer.intent)
            return FailedWrite(
                stem: newer.stem,
                intent: mergedIntent,
                attempts: newer.attempts,
                lastError: newer.lastError,
                timestamp: newer.timestamp
            )
        }
    }

    /// Backoff schedule. Number of retries = `delays.count`; total
    /// attempts = `delays.count + 1`. Internal so tests can swap a
    /// shorter schedule for retry-policy assertions.
    let backoff: [Duration]

    /// Per-stem mutable state. Only the actor mutates this.
    private struct StemState {
        /// Last successfully-written bytes (or last read bytes). Used as
        /// the base for the next mutation so we don't re-read disk.
        var cachedXMPData: Data? = nil
        /// File mtime when `cachedXMPData` was loaded — the drift check.
        var cachedMTime: Date? = nil
        /// `.none` = no pending rating change; `.some(x)` = "next write
        /// should set rating to x" (where x may be nil = clear).
        var pendingRating: Int?? = nil
        var pendingLabel:  String?? = nil
        /// The currently in-flight write task for this stem (nil while idle).
        var running: Task<Void, Never>? = nil

        var hasPending: Bool { pendingRating != nil || pendingLabel != nil }

        /// Pull the pending intent out as a single value. Caller is
        /// expected to clear pendings after snapshotting.
        var pendingIntent: SidecarIntent {
            SidecarIntent(rating: pendingRating, label: pendingLabel)
        }
    }

    private var states: [String: StemState] = [:]
    private let failures: AsyncStream<FailedWrite>.Continuation
    let failureStream: AsyncStream<FailedWrite>

    /// Test-only: number of distinct intent batches the coordinator
    /// has dispatched. Each batch corresponds to one call to
    /// `XMPSidecarWriter.applyIntent` (a batch may internally retry,
    /// but the count bumps only once). Used by coalescing tests.
    private(set) var intentWriteCount: Int = 0

    init(backoff: [Duration] = [.milliseconds(100), .milliseconds(500)]) {
        self.backoff = backoff
        var cont: AsyncStream<FailedWrite>.Continuation!
        self.failureStream = AsyncStream { cont = $0 }
        self.failures = cont
    }

    // MARK: - public write API

    /// Schedule a rating write. Returns immediately; success is
    /// silent, failure is surfaced asynchronously via
    /// `failureStream`. Rapid same-stem calls coalesce — only the
    /// latest rating value reaches disk.
    func writeRating(_ rating: Int?, for entry: PhotoEntry) {
        submitIntent(.setRating(rating), for: entry)
    }

    /// Schedule a label write. Same semantics as `writeRating`.
    func writeLabel(_ label: String?, for entry: PhotoEntry) {
        submitIntent(.setLabel(label), for: entry)
    }

    /// Submit a multi-field intent atomically. Used by undo/redo
    /// snapshot replay and by the failure-retry path so both
    /// fields are guaranteed to coalesce into one disk write.
    func writeIntent(_ intent: SidecarIntent, for entry: PhotoEntry) {
        submitIntent(intent, for: entry)
    }

    /// True iff at least one pending or in-flight write hasn't
    /// finished. Used by the quit-confirm path so we can warn the
    /// user before they lose work.
    var hasInFlightWrites: Bool {
        states.values.contains { $0.running != nil || $0.hasPending }
    }

    /// Cancel every pending and in-flight write, drop all per-stem
    /// state (pendings, cache, running tasks). Used by the close-
    /// shoot path after the user has explicitly confirmed they
    /// want to discard unsaved XMP work. The currently-running
    /// disk attempt may still finish its in-progress system call
    /// — the next loop iteration sees the cleared state and exits
    /// without yielding a failure, so the UI's pill stays clear.
    func discardPendingWrites() {
        for state in states.values {
            state.running?.cancel()
        }
        states.removeAll()
    }

    /// Test-only: wait for every in-flight write to settle. Used
    /// by unit tests that need a deterministic "everything's done"
    /// point without sprinkling Task.sleep across assertions.
    func drain() async {
        // Snapshot first so we don't iterate while the dict mutates.
        // States may be removed/added during awaits as the per-stem
        // loops finish; one pass over the current set is correct
        // because finished loops won't be replaced without a new
        // submit (which would extend the call chain anyway).
        while true {
            let tasks = states.values.compactMap { $0.running }
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
        }
    }

    /// Lower-level entry point that takes a write closure directly
    /// and bypasses intent coalescing. Used by `XMPWriteCoordinatorTests`
    /// to inject failing closures without going through `XMPSidecarWriter`.
    /// Real prod code uses `writeRating` / `writeLabel` / `writeIntent`.
    func enqueueWork(
        stem: String,
        kind: WriteKind,
        work: @Sendable @escaping () throws -> Void
    ) {
        var state = states[stem] ?? StemState()
        let prior = state.running
        let backoffSnap = backoff
        let failuresCont = failures
        let task = Task<Void, Never> { [weak self] in
            await prior?.value
            await Self.runClosureWithRetry(
                stem: stem, intent: kind.asIntent,
                work: work,
                backoff: backoffSnap, failures: failuresCont
            )
            await self?.afterDirectWork(stem: stem)
        }
        state.running = task
        states[stem] = state
    }

    // MARK: - private

    private func submitIntent(_ intent: SidecarIntent, for entry: PhotoEntry) {
        var state = states[entry.stem] ?? StemState()
        if let r = intent.rating { state.pendingRating = r }
        if let l = intent.label  { state.pendingLabel  = l }
        if state.running != nil {
            states[entry.stem] = state
            return
        }
        // Idle → spawn a task that loops until pendings are drained.
        states[entry.stem] = state
        spawnIntentTask(stem: entry.stem, entry: entry)
    }

    private func spawnIntentTask(stem: String, entry: PhotoEntry) {
        let backoffSnap = backoff
        let failuresCont = failures
        let task = Task<Void, Never> { [weak self] in
            await self?.runIntentLoop(
                stem: stem, entry: entry,
                backoff: backoffSnap, failures: failuresCont
            )
        }
        states[stem]?.running = task
    }

    private func runIntentLoop(
        stem: String,
        entry: PhotoEntry,
        backoff: [Duration],
        failures: AsyncStream<FailedWrite>.Continuation
    ) async {
        // The loop body alternates between actor-isolated state
        // moves (takePending / applyOutcome) and the off-actor disk
        // write (runIntentWithRetry). Suspending on the disk write
        // lets writeRating/writeLabel land new pendings; the next
        // takePending picks them up. Exits when takePending returns
        // nil — i.e., no further intent for this stem.
        while let snap = takePending(stem: stem) {
            intentWriteCount += 1
            let outcome = await Self.runIntentWithRetry(
                stem: stem, intent: snap.intent,
                existingData: snap.cachedXMPData,
                cachedMTime: snap.cachedMTime,
                entry: entry,
                backoff: backoff, failures: failures
            )
            applyOutcome(stem: stem, outcome: outcome)
        }
        markIdle(stem: stem)
    }

    private struct PendingSnapshot: Sendable {
        let intent: SidecarIntent
        let cachedXMPData: Data?
        let cachedMTime: Date?
    }

    private func takePending(stem: String) -> PendingSnapshot? {
        guard var state = states[stem], state.hasPending else { return nil }
        let snap = PendingSnapshot(
            intent: state.pendingIntent,
            cachedXMPData: state.cachedXMPData,
            cachedMTime: state.cachedMTime
        )
        state.pendingRating = nil
        state.pendingLabel  = nil
        states[stem] = state
        return snap
    }

    private enum IntentOutcome: Sendable {
        case success(newData: Data, mtime: Date)
        case failure  // already yielded to `failures`
        case cancelled  // discarded via discardPendingWrites — no yield
    }

    private func applyOutcome(stem: String, outcome: IntentOutcome) {
        guard var state = states[stem] else { return }
        switch outcome {
        case .success(let newData, let mtime):
            state.cachedXMPData = newData
            state.cachedMTime = mtime
        case .failure, .cancelled:
            // Disk state is unknown after exhausted retries (or after
            // discard, where the in-flight attempt may or may not
            // have landed) — drop the cache so the next attempt
            // re-reads.
            state.cachedXMPData = nil
            state.cachedMTime = nil
        }
        states[stem] = state
    }

    private func markIdle(stem: String) {
        guard var state = states[stem] else { return }
        state.running = nil
        // Compact: drop entry if nothing's worth remembering.
        if !state.hasPending && state.cachedXMPData == nil {
            states.removeValue(forKey: stem)
        } else {
            states[stem] = state
        }
    }

    /// `enqueueWork` cleanup hook. Doesn't relaunch the intent loop
    /// because `enqueueWork` is only used by tests that exclusively
    /// use the closure path; real prod always uses `writeRating` /
    /// `writeLabel`, which never feed `enqueueWork`.
    private func afterDirectWork(stem: String) {
        guard var state = states[stem] else { return }
        state.running = nil
        if !state.hasPending && state.cachedXMPData == nil {
            states.removeValue(forKey: stem)
        } else {
            states[stem] = state
        }
    }

    // MARK: - off-actor write loops (nonisolated by static)

    /// Nonisolated by virtue of being static — runs on the
    /// cooperative thread pool so disk I/O doesn't block the actor
    /// scheduling other stems' writes.
    private static func runIntentWithRetry(
        stem: String,
        intent: SidecarIntent,
        existingData: Data?,
        cachedMTime: Date?,
        entry: PhotoEntry,
        backoff: [Duration],
        failures: AsyncStream<FailedWrite>.Continuation
    ) async -> IntentOutcome {
        // Drop our local cache view as soon as the first attempt
        // fails — disk state on retry may have changed (a remount
        // race, another tool finishing a write).
        var workingData = existingData
        var workingMTime = cachedMTime
        var lastError: Error?
        for attempt in 0 ... backoff.count {
            // discardPendingWrites cancels the running task; bail
            // silently so we don't repopulate the failures pill the
            // caller is about to clear.
            if Task.isCancelled { return .cancelled }
            do {
                let result = try XMPSidecarWriter.applyIntent(
                    intent,
                    existingData: workingData,
                    cachedMTime: workingMTime,
                    for: entry
                )
                return .success(newData: result.newData, mtime: result.mtime)
            } catch {
                lastError = error
                workingData = nil
                workingMTime = nil
                if attempt < backoff.count {
                    try? await Task.sleep(for: backoff[attempt])
                }
            }
        }
        if Task.isCancelled { return .cancelled }
        let errorString = lastError.map { String(describing: $0) } ?? "unknown"
        failures.yield(FailedWrite(
            stem: stem,
            intent: intent,
            attempts: backoff.count + 1,
            lastError: errorString,
            timestamp: Date()
        ))
        return .failure
    }

    /// Closure variant used only by `enqueueWork` (tests). Emits a
    /// `FailedWrite` carrying the synthesized intent from the kind
    /// if all attempts fail.
    private static func runClosureWithRetry(
        stem: String,
        intent: SidecarIntent,
        work: @Sendable () throws -> Void,
        backoff: [Duration],
        failures: AsyncStream<FailedWrite>.Continuation
    ) async {
        var lastError: Error?
        for attempt in 0 ... backoff.count {
            do {
                try work()
                return
            } catch {
                lastError = error
                if attempt < backoff.count {
                    try? await Task.sleep(for: backoff[attempt])
                }
            }
        }
        let errorString = lastError.map { String(describing: $0) } ?? "unknown"
        failures.yield(FailedWrite(
            stem: stem,
            intent: intent,
            attempts: backoff.count + 1,
            lastError: errorString,
            timestamp: Date()
        ))
    }
}
