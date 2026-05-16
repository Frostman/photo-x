import Foundation
import OSLog

/// Stopwatch for the foreground navigation chain. Begin once per nav event;
/// mark each checkpoint as the chain progresses. Output is one log line per
/// checkpoint with both elapsed-since-begin and delta-since-previous-mark
/// timings.
///
/// MainActor-only on purpose: every link in the nav chain runs on the main
/// actor (or briefly awaits a detached decoder before resuming on main), so
/// we don't need a lock. Background tasks (prefetch) must not call mark or
/// the timings get scrambled.
@MainActor
enum PerfTracker {
    private static var startTime: CFAbsoluteTime = 0
    private static var lastMarkTime: CFAbsoluteTime = 0
    private static var navID: Int = 0
    private static let log = Logger(subsystem: "dev.frostman.PhotoX", category: "perf")

    static func begin(_ label: String) {
        navID += 1
        startTime = CFAbsoluteTimeGetCurrent()
        lastMarkTime = startTime
        log.notice("[\(navID)] BEGIN \(label, privacy: .public)")
    }

    static func mark(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let total = (now - startTime) * 1000
        let delta = (now - lastMarkTime) * 1000
        lastMarkTime = now
        log.notice("[\(navID)] +\(total, format: .fixed(precision: 1))ms (Δ\(delta, format: .fixed(precision: 1))) \(name, privacy: .public)")
    }
}
