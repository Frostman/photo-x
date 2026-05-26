import Foundation

/// PostHog Cloud uploader for anonymous usage counters.
///
/// Direct `URLSession` POST against `/capture/` — no SDK; we control
/// the exact payload (integer counters only, no PII). The actor's
/// only mutable state is the random distinct_id lookup; everything
/// else is derived per call.
///
/// Idempotency: every flush sends ABSOLUTE counter totals (not
/// deltas). PostHog can compute deltas via `windowFunction` in
/// HogQL. This makes the client trivially robust to dropped or
/// duplicated uploads — nothing is "lost", at worst something is
/// delayed or counted twice (which is fine for a rough-aggregate
/// metric).
///
/// API key: ingest-only ("phc_…") — safe to ship in the client
/// bundle. PostHog rate-limits at its edge, so a stolen key just
/// lets a stranger inject garbage into our project; it does NOT
/// grant read access. Read-side API keys (the personal API key
/// used to query PostHog) stay server-side and are never bundled.
actor TelemetryUploader {
    struct Result: Sendable, Equatable {
        let success: Bool
        let httpStatus: Int?
        let error: String?
    }

    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession
    private let defaults: UserDefaults
    private let distinctIDKey: String

    init(endpoint: URL = URL(string: "https://us.i.posthog.com/capture/")!,
         apiKey: String,
         session: URLSession = .shared,
         defaults: UserDefaults = AppDefaults.shared,
         distinctIDKey: String = SettingsKey.telemetryAnonymousID)
    {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.session = session
        self.defaults = defaults
        self.distinctIDKey = distinctIDKey
    }

    /// Flush a snapshot to PostHog. No-op (returns success=false) if
    /// `apiKey` is empty so DEBUG builds without an injected key
    /// can run without spamming the network. Caller is expected to
    /// have already called `UsageMetrics.flushPending()` so the
    /// `counters` argument reflects what's on disk too.
    func flush(counters: UsageMetrics.Counters,
               firstLaunchAt: Date,
               appVersion: String,
               appDescribe: String,
               osVersion: String) async -> Result
    {
        guard !apiKey.isEmpty else {
            return Result(success: false, httpStatus: nil,
                          error: "apiKey is empty (no-op)")
        }
        let distinctID = self.distinctID()
        let payload: [String: Any] = [
            "api_key": apiKey,
            "event": "usage_snapshot",
            "distinct_id": distinctID,
            "properties": [
                // PostHog magic prefixes: $lib / $lib_version /
                // $os / $os_version get cohort + filter affordances
                // in the dashboard automatically. We mirror
                // $lib_version into the explicitly-named
                // `app_version` for queries that prefer readable
                // property names.
                "$lib": "photox",
                "$lib_version": appVersion,
                "$os": "macOS",
                "$os_version": osVersion,
                "app_version":       appVersion,
                // Full git-derived string ("v0.267.0-c4ed16809-dirty"
                // for releases, "v0.0.0-dev-<sha>[-dirty]" for
                // dev). Dev builds otherwise all report
                // app_version="0.0.0" and become indistinguishable
                // from each other in the dashboard.
                "app_describe":      appDescribe,
                "app_opens":         counters.appOpens,
                "photos_seen":       counters.photosSeen,
                "shoots_opened":     counters.shootsOpened,
                "exports_completed": counters.exportsCompleted,
                "images_exported":   counters.imagesExported,
                "scores_set":        counters.scoresSet,
                "first_launch_at":   Self.iso8601(firstLaunchAt),
            ]
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.sortedKeys])
        } catch {
            return Result(success: false, httpStatus: nil,
                          error: "serialize: \(error.localizedDescription)")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        // 5-second hard cap so a stalled flush can't keep the quit
        // hook waiting forever (the AppDelegate gives us 3 s and
        // proceeds regardless, but tightening at the request level
        // is belt-and-braces).
        req.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200 ..< 300).contains(status)
            return Result(success: ok, httpStatus: status, error: nil)
        } catch {
            return Result(success: false, httpStatus: nil,
                          error: error.localizedDescription)
        }
    }

    /// Lazy-generates and persists a random UUID on first call.
    /// Write-once: subsequent calls in this install return the same
    /// string. `UsageMetrics.reset()` and the telemetry toggle do
    /// NOT clear this key (see project plan).
    func distinctID() -> String {
        if let existing = defaults.string(forKey: distinctIDKey),
           !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString
        defaults.set(new, forKey: distinctIDKey)
        return new
    }

    // MARK: - Helpers

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
