import Foundation
import Observation

// MARK: - Output

/// Output of the export planning phase — everything the copy
/// loop and orphan-removal need, computed once with parallel
/// I/O so the runtime can hand the same metadata to every
/// destination's planner call without re-walking the disk.
struct ExportPlanningResult: Sendable {
    /// Source file URL → byte size. One stat per source file
    /// for the whole export run, shared across every
    /// destination via `ExportPlanner.plan(...,sourceSizes:)`.
    let sourceSizes: [URL: Int64]
    /// Per-destination snapshot keyed by `Destination.id`.
    /// Every destination passed into the planning phase gets
    /// an entry (even an empty one) so callers can always
    /// look up by ID without an `if let`.
    let perDestination: [UUID: DestinationPlan]
    /// Source-side stat / access errors collected during the
    /// sweep. Empty on the happy path. Surfaced on the
    /// source card so the user can see which files couldn't
    /// be read before the export proceeds.
    let sourceErrors: [(URL, String)]
}

/// Per-destination output of the planning phase. Captures
/// the existing contents at `<dest.path>/<projectName>/` so
/// the copy phase can short-circuit overwrite decisions
/// without another stat sweep — and so the "destination not
/// empty" guard can fire without a separate readdir.
struct DestinationPlan: Sendable {
    /// All non-hidden items currently at
    /// `<dest.path>/<projectName>/`. Empty when the folder
    /// doesn't exist or contains only hidden items.
    /// Filename (last path component) → name only; the
    /// actual stat snapshots aren't required for the
    /// "blocked" decision and the copy loop continues to
    /// stat lazily for safety against race conditions.
    let existingFilenames: Set<String>
    /// Set by planning when `existingFilenames.isEmpty == false`
    /// AND `destination.allowNonEmpty == false`. The runner
    /// short-circuits the copy for this destination to a
    /// `.failed(blockedReason, nil)` state when set.
    let blockedReason: String?
}

// MARK: - Progress

/// Observable per-task progress. The planning phase owns one
/// `TaskProgress` for the source and one per destination so
/// each card can render its own progress bar independently
/// rather than sharing one aggregate. All mutations are
/// MainActor-isolated; subtasks hop back to MainActor before
/// updating.
@Observable @MainActor
final class TaskProgress {
    private(set) var done: Int = 0
    private(set) var total: Int = 0
    private(set) var errors: [(URL, String)] = []

    func bump(_ delta: Int = 1) { done += delta }
    func setTotal(_ n: Int) { total = n }
    func recordError(_ url: URL, _ message: String) {
        errors.append((url, message))
    }

    /// 0…1; 0 when total is 0 (planning hasn't started yet).
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(done) / Double(total))
    }
}

/// Top-level container that the runner publishes and the UI
/// observes. Each destination registers its own
/// `TaskProgress` slot before its subtask starts so the row
/// can bind to a stable reference for the duration of the
/// planning phase.
@Observable @MainActor
final class PlanningPhaseProgress {
    let source = TaskProgress()
    private(set) var destinations: [UUID: TaskProgress] = [:]

    func registerDestination(_ id: UUID) {
        // Idempotent — the runner may register the same id
        // twice if startOne is called concurrently for some
        // pathological case; second registration is a no-op
        // so the existing TaskProgress reference stays
        // valid for any subscribed View.
        if destinations[id] == nil {
            destinations[id] = TaskProgress()
        }
    }
}
