import Foundation

/// Actor that orders batches for a single indexing pipeline (exiftool /
/// XMP / thumbnails). Each pipeline owns its own queue but all three see
/// the same `prioritize` signals from the UI, so navigating bumps a
/// pair's batch to the head of every pipeline at once.
///
/// State invariants:
///   - Every batch id is exactly one of `.pending`, `.inProgress`, `.done`.
///   - `popNext()` returns each batch id AT MOST ONCE across all concurrent
///     callers (the actor serializes the claim → mark-in-progress step).
///   - `prioritize(_:)` is a no-op for ids that are already `.inProgress`
///     or `.done` — the work isn't redone.
///   - `markDone(_:)` is idempotent.
///
/// The queue does not know about the shoot, the pipeline kind, or
/// cancellation generation — those concerns stay on `ViewerState`.
actor BatchQueue {
    enum State: Sendable, Hashable {
        case pending
        case inProgress
        case done
    }

    private var states: [Int: State]
    /// Priority list. Head is the next id `popNext` will hand out. Only
    /// contains ids whose state is `.pending` — once claimed they leave
    /// the list. Default order at init is `0 ..< batchCount`.
    private var order: [Int]
    private var doneCount: Int = 0

    init(batchCount: Int) {
        var s: [Int: State] = [:]
        var o: [Int] = []
        s.reserveCapacity(batchCount)
        o.reserveCapacity(batchCount)
        for id in 0 ..< batchCount {
            s[id] = .pending
            o.append(id)
        }
        self.states = s
        self.order = o
    }

    /// Move a pending batch to the head of the priority list. No-op when
    /// the batch is already running or finished — neither needs re-doing
    /// and re-ordering done work would break the no-double-load invariant.
    func prioritize(_ id: Int) {
        guard states[id] == .pending else { return }
        if let idx = order.firstIndex(of: id), idx > 0 {
            order.remove(at: idx)
            order.insert(id, at: 0)
        }
    }

    /// Claim the next pending batch; transitions it to `.inProgress` and
    /// removes it from the priority list. Returns nil when nothing remains
    /// to claim (queue empty OR everything is in-progress or done).
    func popNext() -> Int? {
        guard let id = order.first else { return nil }
        order.removeFirst()
        states[id] = .inProgress
        return id
    }

    /// Mark a batch finished. Idempotent — re-marking a `.done` id is fine.
    /// `inProgress` → `done` increments `doneCount`; calls on `.pending`
    /// or `.done` ids leave the counter alone.
    func markDone(_ id: Int) {
        if states[id] == .inProgress {
            states[id] = .done
            doneCount += 1
        }
    }

    /// Number of batches that have completed. Cheap snapshot for the
    /// progress ticker.
    func snapshotDoneCount() -> Int { doneCount }

    /// Inspect a batch's current state. Mainly for tests.
    func state(of id: Int) -> State? { states[id] }

    /// Count of batches with the given state. Mainly for tests.
    func count(in state: State) -> Int {
        states.values.reduce(0) { $0 + ($1 == state ? 1 : 0) }
    }
}
