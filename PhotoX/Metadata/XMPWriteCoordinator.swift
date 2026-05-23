import Foundation

/// All XMP sidecar writes flow through this actor. Two reasons:
///
/// 1. **Per-stem serialization** — two writes to the same `.xmp`
///    file must never race. Each stem has its own dedicated chain
///    of pending tasks; the next write awaits the previous one.
///    Writes for different stems run concurrently.
///
/// 2. **Retry on transient failure** — the disk write is attempted
///    up to 3 times (initial + 2 retries) with 100 ms then 500 ms
///    backoff. If all attempts fail, a `FailedWrite` event is
///    emitted on `failureStream` so the UI can surface it
///    persistently (the titlebar pill).
///
/// **Why this matters**: saving culling decisions is the project's
/// single most important promise (see project memory
/// `project_xmp_write_reliability.md`). Every XMP write in the app
/// should go through this coordinator — never directly call
/// `XMPSidecarWriter.update…` from a fire-and-forget `Task`.
actor XMPWriteCoordinator {
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
    }

    struct FailedWrite: Sendable, Equatable {
        let stem: String
        let kind: WriteKind
        let attempts: Int
        let lastError: String
        let timestamp: Date
    }

    /// Backoff schedule. Number of retries = `delays.count`; total
    /// attempts = `delays.count + 1`. Internal so tests can swap a
    /// shorter schedule for retry-policy assertions.
    let backoff: [Duration]

    /// Map from stem → (most recent task scheduled for that stem,
    /// monotonically-increasing generation). The generation lets
    /// the completion handler clean up the dict only if no newer
    /// task has replaced it — Task isn't Equatable so we can't
    /// compare identity directly.
    private var perStem: [String: (task: Task<Void, Never>, generation: Int)] = [:]
    private var generationCounter: Int = 0
    private let failures: AsyncStream<FailedWrite>.Continuation
    let failureStream: AsyncStream<FailedWrite>

    init(backoff: [Duration] = [.milliseconds(100), .milliseconds(500)]) {
        self.backoff = backoff
        var cont: AsyncStream<FailedWrite>.Continuation!
        self.failureStream = AsyncStream { cont = $0 }
        self.failures = cont
    }

    /// Schedule a rating write. Returns immediately; success is
    /// silent, failure is surfaced asynchronously via
    /// `failureStream`.
    func writeRating(_ rating: Int?, for entry: PhotoEntry) {
        enqueue(stem: entry.stem, kind: .rating(rating)) {
            try XMPSidecarWriter.updateRating(rating, for: entry)
        }
    }

    /// Schedule a label write. Same semantics as `writeRating`.
    func writeLabel(_ label: String?, for entry: PhotoEntry) {
        enqueue(stem: entry.stem, kind: .label(label)) {
            try XMPSidecarWriter.updateLabel(label, for: entry)
        }
    }

    /// True iff at least one pending or in-flight write hasn't
    /// finished. Used by the quit-confirm path so we can warn the
    /// user before they lose work.
    var hasInFlightWrites: Bool {
        !perStem.isEmpty
    }

    /// Test-only: wait for every in-flight write to settle. Used
    /// by unit tests that need a deterministic "everything's done"
    /// point without sprinkling Task.sleep across assertions.
    func drain() async {
        let snapshot = perStem.values.map { $0.task }
        for task in snapshot { await task.value }
    }

    /// Lower-level entry point that takes the write closure directly.
    /// Used by writeRating/writeLabel and by tests that need to
    /// inject a failing closure without going through XMPSidecarWriter.
    func enqueueWork(
        stem: String,
        kind: WriteKind,
        work: @Sendable @escaping () throws -> Void
    ) {
        enqueue(stem: stem, kind: kind, work: work)
    }

    // MARK: - private

    private func enqueue(
        stem: String,
        kind: WriteKind,
        work: @Sendable @escaping () throws -> Void
    ) {
        generationCounter &+= 1
        let myGen = generationCounter
        let prior = perStem[stem]?.task
        let backoffSnap = backoff
        // Capture the continuation directly so the I/O closure
        // (which runs off-actor in a detached Task) can emit
        // failures without bouncing back through actor isolation.
        let failuresCont = failures
        let task = Task<Void, Never> { [weak self] in
            // Wait for the previous write to this stem to finish so
            // we never have two concurrent writers touching the
            // same .xmp file. nil prior = first write for this stem.
            await prior?.value
            await Self.runWithRetry(
                stem: stem, kind: kind, work: work,
                backoff: backoffSnap, failures: failuresCont
            )
            // Drop ourselves from the dict if no newer enqueue has
            // replaced us (compare generation). This is what makes
            // hasInFlightWrites eventually read false when idle.
            await self?.clearIfStillCurrent(stem: stem, generation: myGen)
        }
        perStem[stem] = (task, myGen)
    }

    private func clearIfStillCurrent(stem: String, generation: Int) {
        if perStem[stem]?.generation == generation {
            perStem[stem] = nil
        }
    }

    /// Nonisolated: runs off the actor's executor so the actual
    /// disk I/O (and sleep delays during backoff) doesn't block
    /// other writes from being scheduled. The actor's job is
    /// scheduling + dedup; the I/O itself is best done elsewhere.
    private static func runWithRetry(
        stem: String,
        kind: WriteKind,
        work: @Sendable () throws -> Void,
        backoff: [Duration],
        failures: AsyncStream<FailedWrite>.Continuation
    ) async {
        var lastError: Error?
        for attempt in 0 ... backoff.count {
            do {
                try work()
                return                                    // success
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
            kind: kind,
            attempts: backoff.count + 1,
            lastError: errorString,
            timestamp: Date()
        ))
    }
}
