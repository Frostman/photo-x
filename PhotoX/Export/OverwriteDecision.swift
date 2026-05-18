import Foundation

/// Decides what the copy loop should do with a single source→destination
/// file pair. Pure — depends only on stat-able attributes + the policy +
/// whether the file is an XMP sidecar. Lives outside ExportRunner so the
/// decision matrix can be exhaustively unit-tested without any IO.
enum CopyDecision: Equatable, Sendable {
    /// Source should be copied to the destination. `removeFirst` is true
    /// when the destination already exists and must be deleted before
    /// `FileManager.copyItem` (which fails on a pre-existing destination).
    case write(removeFirst: Bool)
    /// Source should be skipped.
    case skip
}

/// Just enough of a stat to drive the decision. Lets tests fabricate
/// scenarios without touching the filesystem.
struct FileSnapshot: Equatable, Sendable {
    /// nil = file does not exist
    let size: Int64?
    /// nil = file does not exist
    let mtime: Date?

    static let missing = FileSnapshot(size: nil, mtime: nil)
    var exists: Bool { size != nil && mtime != nil }
}

enum OverwriteDecision {
    /// Mtime delta below this threshold treats the timestamps as equal —
    /// filesystems quantize mtimes (HFS+ is 1s), tar / cp / rsync round, and
    /// repeated identical writes can land on slightly different seconds.
    static let mtimeEqualityToleranceSeconds: TimeInterval = 1.0

    /// Decide whether to copy or skip. Two invariants apply on top of the
    /// per-policy logic:
    ///
    /// 1. **Universal "same size + mtime within 1s ⇒ skip"** — applies
    ///    regardless of policy (cheap idempotent re-runs are the whole
    ///    point of having a sync-style export).
    /// 2. **XMP-only "never regress a newer sidecar"** — applies regardless
    ///    of policy. XMPs are mutable culling state; the user can be
    ///    editing them on the destination side (e.g. a Lightroom catalog
    ///    sharing the sidecar). Overwriting a newer XMP with an older one
    ///    would silently lose work.
    static func decide(
        source: FileSnapshot,
        destination: FileSnapshot,
        isXMP: Bool,
        policy: ExportSettings.OverwritePolicy
    ) -> CopyDecision {
        // Source must exist to copy at all. If it doesn't, callers shouldn't
        // ask — but defend against it cleanly.
        guard source.exists else { return .skip }

        // Destination missing → unconditional write, no remove needed.
        guard destination.exists,
              let srcSize = source.size, let srcMtime = source.mtime,
              let dstSize = destination.size, let dstMtime = destination.mtime
        else {
            return .write(removeFirst: false)
        }

        // Universal sameness check.
        if srcSize == dstSize,
           abs(srcMtime.timeIntervalSince(dstMtime)) < mtimeEqualityToleranceSeconds {
            return .skip
        }

        // XMP regression guard (kicks in regardless of policy).
        if isXMP, dstMtime > srcMtime {
            return .skip
        }

        switch policy {
        case .alwaysOverwrite:
            return .write(removeFirst: true)
        case .skipIfExists:
            return .skip
        case .skipUnchangedElseOverwrite:
            return .write(removeFirst: true)
        case .skipUnchangedElseNewerOnly:
            return srcMtime > dstMtime ? .write(removeFirst: true) : .skip
        }
    }
}
