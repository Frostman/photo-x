import OSLog

enum Log {
    static let app = Logger(subsystem: "dev.frostman.PhotoX", category: "app")
    static let decode = Logger(subsystem: "dev.frostman.PhotoX", category: "decode")
    static let canvas = Logger(subsystem: "dev.frostman.PhotoX", category: "canvas")
    /// All cache hit / miss / clear / insert events — `MTLTextureCache`,
    /// `PreviewBytesCache`, future caches. Filter Console.app on
    /// `category:cache` to see only cache traffic and nothing else.
    /// Lifecycle (`CLEAR`) lines stay at `.notice`; per-nav `HIT` /
    /// `MISS` are gated `#if DEBUG` at the call site since they fire
    /// per image.
    static let cache = Logger(subsystem: "dev.frostman.PhotoX", category: "cache")

    /// DEBUG-only update-lifecycle notice. Self-update fires a lot
    /// of per-check / per-callback chatter (probe ticks, scheduler
    /// arms, popup state, dismiss/swap dance) that's invaluable for
    /// debugging but pure noise in production. Release builds compile
    /// the body away and skip the `message()` autoclosure — call sites
    /// stay clean (no `#if DEBUG` sprinkling).
    ///
    /// Errors stay on `Log.app.error` (release-safe). The "v_X newly
    /// available" lifecycle line bypasses this helper and uses
    /// `Log.app.notice` directly so it survives in release.
    static func updateDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        app.notice("update: \(text, privacy: .public)")
        #endif
    }
}
