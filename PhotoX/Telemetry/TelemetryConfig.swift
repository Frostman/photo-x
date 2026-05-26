import Foundation

/// Single source of truth for the two cadence knobs the telemetry
/// system exposes. Both the actual sleep / interval call sites AND
/// the user-facing help/footer text read from these so the numbers
/// can never drift between the code and the UI copy.
///
/// Not user-configurable (intentionally): these are operational
/// defaults, not preferences. Tightening them trades CPU/network
/// for crash safety and freshness.
enum TelemetryConfig {
    /// How often the in-memory counter delta is drained to the
    /// on-disk UserDefaults blob via read-modify-write. Always
    /// running — the local stats window benefits from it even
    /// when telemetry uploads are disabled. Worst-case data loss
    /// from a hard crash is everything since the previous tick.
    static let localPersistInterval: Duration = .seconds(5 * 60)

    /// How often the on-disk totals are uploaded to PostHog Cloud.
    /// Only runs when `settings.telemetryEnabled` is true. Quit
    /// also fires an extra upload via the AppDelegate's
    /// `applicationShouldTerminate` hook, so the worst-case
    /// upload delay is min(interval, time-since-last-quit).
    static let uploadInterval: Duration = .seconds(6 * 3600)

    /// Human-readable forms for help text / footers. Derived from
    /// the Duration constants above so the displayed cadence
    /// always matches the actual sleep value.
    static var localPersistIntervalDescription: String {
        formatDuration(localPersistInterval)
    }
    static var uploadIntervalDescription: String {
        formatDuration(uploadInterval)
    }

    /// Format a Duration as "5 minutes" / "6 hours" / "30 seconds".
    /// Picks the largest whole unit. Only handles seconds / minutes
    /// / hours — extend if a future cadence lands on a day boundary.
    private static func formatDuration(_ d: Duration) -> String {
        let seconds = Int(d.components.seconds)
        if seconds % 3600 == 0 {
            let hours = seconds / 3600
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}
