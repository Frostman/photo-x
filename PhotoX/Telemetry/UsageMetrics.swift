import Foundation
import Observation

/// Lifetime usage counters surfaced in the Stats window and (when the
/// user opts in) uploaded to PostHog as anonymous integer events.
///
/// Two-tier design so the hot call sites — `commitDisplayed`,
/// `setRating`, `setLabel` — never block the main thread on
/// JSON encoding or UserDefaults writes:
///
/// • `pending` is incremented in-place by the record* mutators
///   (one Int += 1, no I/O).
/// • A background `Task` drains `pending` into the on-disk blob
///   every `persistInterval` (default `TelemetryConfig.localPersistInterval`)
///   via a read-modify-write, so a second PhotoX window /
///   process touching the same UserDefaults suite can't clobber
///   our increments.
///
/// `total = persisted + pending` is what the UI shows.
@MainActor @Observable
final class UsageMetrics {
    struct Counters: Codable, Equatable, Sendable {
        var appOpens         = 0
        var photosSeen       = 0
        var shootsOpened     = 0
        var exportsCompleted = 0
        var imagesExported   = 0
        var scoresSet        = 0

        static let zero = Counters()

        static func + (a: Self, b: Self) -> Self {
            Counters(
                appOpens:         a.appOpens         + b.appOpens,
                photosSeen:       a.photosSeen       + b.photosSeen,
                shootsOpened:     a.shootsOpened     + b.shootsOpened,
                exportsCompleted: a.exportsCompleted + b.exportsCompleted,
                imagesExported:   a.imagesExported   + b.imagesExported,
                scoresSet:        a.scoresSet        + b.scoresSet
            )
        }

        static func - (a: Self, b: Self) -> Self {
            Counters(
                appOpens:         a.appOpens         - b.appOpens,
                photosSeen:       a.photosSeen       - b.photosSeen,
                shootsOpened:     a.shootsOpened     - b.shootsOpened,
                exportsCompleted: a.exportsCompleted - b.exportsCompleted,
                imagesExported:   a.imagesExported   - b.imagesExported,
                scoresSet:        a.scoresSet        - b.scoresSet
            )
        }
    }

    enum Key {
        static let counters        = "metrics.counters"
        static let firstLaunchAt   = "metrics.firstLaunchAt"
        static let lastPersistedAt = "metrics.lastPersistedAt"
        /// Wall-clock of the last successful PostHog upload. Set by
        /// `markUploaded(at:)`; reads back via UserDefaults on init.
        /// Stays set even after a telemetry toggle-off (so the user
        /// can see when the last upload happened).
        static let lastUploadedAt  = "metrics.lastUploadedAt"
    }

    /// Last on-disk total observed by THIS process. The stats window
    /// shows `total` (persisted + pending), so an external write to
    /// the same suite isn't reflected until the next persist cycle —
    /// that's an acceptable simplification for the multi-window case.
    private(set) var persisted: Counters

    /// In-memory delta since the last successful persist. Drained
    /// inside `persistOnce` via subtract-after-write so increments
    /// happening DURING the persist window stay queued.
    private(set) var pending: Counters = .zero

    /// What every UI surface reads.
    var total: Counters { persisted + pending }

    /// First time the app was ever launched (defined as "the first
    /// time UsageMetrics was instantiated against this UserDefaults
    /// suite without an existing firstLaunchAt"). Persisted once.
    private(set) var firstLaunchAt: Date

    /// Wall-clock of the last successful disk persist in THIS process.
    /// nil if nothing has been persisted yet. Used by the stats window
    /// footer + by the periodic-flush task to decide whether to ping
    /// PostHog. Persisted to UserDefaults so it survives process restart.
    private(set) var lastPersistedAt: Date?

    /// Wall-clock of the last successful PostHog upload. nil if never
    /// uploaded (telemetry disabled, no API key, or hasn't ticked
    /// once yet). Persisted to UserDefaults so the stats window's
    /// "last sent" line survives across launches.
    private(set) var lastUploadedAt: Date?

    private let store: UserDefaults
    private let persistInterval: Duration
    private var persistTask: Task<Void, Never>?

    init(store: UserDefaults = AppDefaults.shared,
         persistInterval: Duration = TelemetryConfig.localPersistInterval,
         startBackgroundLoop: Bool = true)
    {
        self.store = store
        self.persistInterval = persistInterval
        self.persisted = Self.loadCounters(store)
        if let stored = store.object(forKey: Key.firstLaunchAt) as? Date {
            self.firstLaunchAt = stored
        } else {
            let now = Date()
            store.set(now, forKey: Key.firstLaunchAt)
            self.firstLaunchAt = now
        }
        self.lastPersistedAt = store.object(forKey: Key.lastPersistedAt) as? Date
        self.lastUploadedAt  = store.object(forKey: Key.lastUploadedAt)  as? Date

        if startBackgroundLoop {
            startBackgroundPersistLoop()
        }
    }

    /// Record that a successful PostHog upload landed at `date`.
    /// Persisted to UserDefaults so the stats window can show
    /// "last sent" across launches. Called by ViewerState's
    /// `uploadTelemetryNow` after the uploader returns success.
    func markUploaded(at date: Date) {
        lastUploadedAt = date
        store.set(date, forKey: Key.lastUploadedAt)
    }

    // UsageMetrics lives for the entire app lifetime — the persist
    // task captures weak self, so when the process is about to exit
    // (or, in tests, the instance is dropped) the loop quietly
    // returns nil on the next wake. Explicit cancel from a non-
    // MainActor deinit would need MainActor.assumeIsolated; not
    // worth it for a singleton.

    // MARK: - Record (hot path — O(1), no I/O)

    func recordAppOpen()                        { pending.appOpens += 1 }
    func recordPhotoSeen()                      { pending.photosSeen += 1 }
    func recordShootOpened()                    { pending.shootsOpened += 1 }
    func recordScoreSet()                       { pending.scoresSet += 1 }
    func recordExportCompleted(imageCount: Int) {
        pending.exportsCompleted += 1
        pending.imagesExported   += imageCount
    }

    // MARK: - Persist

    /// Force-persist now. Called from the app-quit hook, the
    /// telemetry toggle-on path, and `reset()`. Safe to call when
    /// `pending` is empty (becomes a no-op).
    func flushPending() async { await persistOnce() }

    /// Zero both tiers and write zero to disk. The "Reset stats"
    /// button. Does NOT touch the telemetry anonymous UUID — that
    /// key lives under settings.* and is write-once for the install.
    func reset() async {
        pending = .zero
        persisted = .zero
        await Task.detached(priority: .utility) { [store] in
            Self.saveCounters(.zero, store: store)
        }.value
        let now = Date()
        store.set(now, forKey: Key.lastPersistedAt)
        lastPersistedAt = now
    }

    // MARK: - Background loop

    private func startBackgroundPersistLoop() {
        let interval = persistInterval
        persistTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.persistOnce()
            }
        }
    }

    /// Read-modify-write: snapshot pending, off-main re-read the
    /// on-disk blob (so another window's writes survive), add the
    /// delta, write back. Drain only the snapshot we persisted so
    /// any increments that happened during the I/O stay queued
    /// for the next pass.
    private func persistOnce() async {
        let delta = pending
        guard delta != .zero else { return }
        let merged: Counters = await Task.detached(priority: .utility) { [store] in
            let onDisk = Self.loadCounters(store)
            let combined = onDisk + delta
            Self.saveCounters(combined, store: store)
            return combined
        }.value
        persisted = merged
        pending = pending - delta
        let now = Date()
        store.set(now, forKey: Key.lastPersistedAt)
        lastPersistedAt = now
    }

    // MARK: - Disk I/O
    //
    // `nonisolated` so the detached background-persist Task can call
    // them off the main thread without re-hopping. Pure functions
    // over the passed-in `store`; no shared state, safe to call from
    // any actor / queue.

    nonisolated static func loadCounters(_ store: UserDefaults) -> Counters {
        guard let data = store.data(forKey: Key.counters),
              let decoded = try? JSONDecoder().decode(Counters.self, from: data)
        else { return .zero }
        return decoded
    }

    nonisolated static func saveCounters(_ counters: Counters, store: UserDefaults) {
        guard let data = try? JSONEncoder().encode(counters) else { return }
        store.set(data, forKey: Key.counters)
    }
}
