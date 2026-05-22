import AppKit
import Foundation
import os
import Sparkle

/// Wraps raw `SPUUpdater` with our custom `PhotoXUserDriver`. There
/// is no `SPUStandardUserDriver` and therefore no Sparkle-rendered
/// modal sheet anywhere in the app — every user-facing surface is
/// our own popup (`UpdateInstallWindowController`) or NSAlert.
///
/// **Why a custom user driver this time?** A previous wrapper-style
/// attempt (commit `92472cd`) wrapped `SPUStandardUserDriver` and
/// broke twice: gentle-reminders stopped firing and extraction hung
/// mid-download. The fix from that revert (`8ad0f06`) accepted the
/// 4-button standard sheet to keep updates working. This rewrite
/// takes the other lane — implement `SPUUserDriver` directly, no
/// inner standard driver. Every reply/acknowledgement block in
/// `PhotoXUserDriver` is invoked so Sparkle's state machine never
/// stalls.
///
/// Flow:
///
///  1. Background poll (every 5 min) finds an update →
///     `PhotoXUserDriver.showUpdateFound(...)` with `userInitiated=false`
///     → flip `availableUpdate` to `.available(...)`, immediately
///     `reply(.dismiss)` so Sparkle releases.
///  2. Pill appears in the titlebar. Newer version on next poll →
///     same hook fires with the newer item → pill label updates.
///  3. User clicks pill or menu "Check for Updates" → user-initiated
///     check → `showUpdateFound(...)` with `userInitiated=true` →
///     custom popup opens with version + release notes + Cancel /
///     Install Update.
///  4. Cancel at any stage keeps the pill visible.
///  5. Install Update → Sparkle downloads + extracts; the popup's
///     state transitions render progress in-place. Ready-to-install
///     is auto-confirmed (no second sheet). App quits + relaunches.
///  6. `updaterWillRelaunchApplication` captures the open shoot URL
///     so `PhotoXApp.bootstrap()` can resume it on the next launch.
@MainActor
@Observable
final class UpdaterController {
    enum AvailableUpdate: Equatable {
        case none
        case available(version: String, item: SUAppcastItem)

        static func == (lhs: AvailableUpdate, rhs: AvailableUpdate) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case let (.available(va, _), .available(vb, _)): return va == vb
            default: return false
            }
        }
    }

    private(set) var availableUpdate: AvailableUpdate = .none

    /// Mirrors `SPUUpdater.canCheckForUpdates`. Sparkle flips this to
    /// false while a session is in progress — which, in our "hold the
    /// reply until install" model, is most of the time the pill is
    /// showing. Read `menuCheckForUpdatesEnabled` instead of this
    /// directly when gating the Check-for-Updates menu item, so the
    /// menu stays clickable while we have a cached offer to replay.
    var canCheckForUpdates: Bool = false

    /// Drives `disabled(_:)` on the Check for Updates menu item.
    /// True iff Sparkle is idle (so a fresh check would actually run)
    /// OR we have a pending offer that the menu can replay via
    /// `openCachedOffer()`. Either case results in a useful action.
    var menuCheckForUpdatesEnabled: Bool {
        if case .available = availableUpdate { return true }
        return canCheckForUpdates
    }

    /// Closure the host sets so we can capture the currently-open
    /// shoot folder URL right before Sparkle quits the app for the
    /// install. Optional — nil means no reopen will be staged.
    var shootURLProvider: (() -> URL?)?

    /// The custom user driver.
    let userDriver = PhotoXUserDriver()

    /// The most recently-parsed appcast (refreshed every check). Used
    /// by `PhotoXUserDriver` to aggregate release notes from every
    /// item between the user's current version and the offered
    /// target — so a v0.220 → v0.225 jump surfaces all 5 changelogs.
    /// Nil until Sparkle's first fetch completes.
    private(set) var lastAppcast: SUAppcast?

    private let updater: SPUUpdater
    private let updaterDelegate: UpdaterDelegate
    private var canCheckObservation: NSKeyValueObservation?
    /// Drives our supplementary 5-min background polling. Sparkle's
    /// own scheduler clamps `SUScheduledCheckInterval` to a hard
    /// minimum of 1 hour regardless of what we put in `Info.plist`,
    /// which is too slow for the "cut a release → see the pill"
    /// workflow we want. This timer rides on top and triggers extra
    /// `checkForUpdatesInBackground()` calls between Sparkle's own
    /// hourly ticks. Sparkle de-dupes via its `sessionInProgress`
    /// flag, so overlapping cycles are safe.
    private var supplementaryPollTimer: Timer?
    private static let supplementaryPollInterval: TimeInterval = 5 * 60
    /// Set on every user-initiated `checkForUpdates()`. The user
    /// driver's `showUpdateNotFoundWithError(...)` consumes it to
    /// decide whether to surface the "you're up to date" alert.
    /// Without this flag, background no-update polls would nag the
    /// user every 5 minutes.
    private var pendingUserInitiated: Bool = false

    init() {
        // Always neutralise any persisted skip — we no longer
        // surface a Skip Version button, so leaving a stale
        // SUSkippedVersion in defaults would silently suppress
        // the very update we want to push.
        Self.clearSkippedVersionDefaults()

        // Sparkle runs in both Debug and Release. Debug builds
        // advertise CFBundleShortVersionString=0.0.0 (forced by
        // `just dev`), so every prod-appcast item is "newer" — every
        // `just dev` rebuild surfaces the pill within ~10 s and the
        // full download → install → relaunch cycle works against the
        // real prod appcast, despite the dev/prod bundle-ID split.
        // That's the primary workflow for end-to-end verifying the
        // self-update popup without cutting a release.
        let delegate = UpdaterDelegate()
        let sparkle = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: delegate
        )
        self.updater = sparkle
        self.updaterDelegate = delegate
        // Force policy on every launch — these persist in user
        // defaults, so we rewrite to keep them in sync with the
        // documented policy regardless of any prior toggling.
        sparkle.automaticallyChecksForUpdates = true
        sparkle.automaticallyDownloadsUpdates = false
        self.canCheckForUpdates = sparkle.canCheckForUpdates

        // Stored properties initialized — now safe to reach `self`.
        userDriver.controller = self
        delegate.controller = self
        self.canCheckObservation = sparkle.observe(
            \.canCheckForUpdates, options: [.new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }

        do {
            try sparkle.start()
        } catch {
            Log.app.error("SPUUpdater.start failed: \(String(describing: error), privacy: .public)")
        }
        // Fire an immediate first check at launch. Sparkle's
        // documented pattern for this is `checkForUpdatesInBackground`
        // — the alternative `resetUpdateCycle` only re-arms the
        // timer and does NOT trigger an immediate check.
        sparkle.checkForUpdatesInBackground()

        // Start the supplementary 5-min polling timer. See the
        // property's doc comment — Sparkle's own scheduler is locked
        // at a 1-hour minimum, so without this the user wouldn't see
        // a newly-cut release for up to an hour.
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.supplementaryPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleSupplementaryTick()
            }
        }
        self.supplementaryPollTimer = timer
    }

    /// One tick of the supplementary polling timer. Two paths:
    ///
    /// - **No offer pending**: defer to Sparkle's own
    ///   `checkForUpdatesInBackground()` — it'll fetch the appcast,
    ///   either find a newer item (→ `showUpdateFound`) or no-op.
    ///
    /// - **Offer pending** (we're holding a reply for v_old): Sparkle's
    ///   `sessionInProgress` flag would silently drop a
    ///   `checkForUpdatesInBackground` call. Instead, probe the
    ///   appcast directly via `AppcastProbe`. If a strictly newer
    ///   build is on the feed, tear down the held offer (which ends
    ///   Sparkle's session) and re-trigger Sparkle so the new item
    ///   surfaces. If not newer, do nothing — Sparkle would no-op
    ///   anyway, and we'd just be burning a network round-trip per
    ///   tick if we tried.
    ///
    /// We refuse to swap while the popup is on-screen — yanking the
    /// "v_old available" popup out from under a user who's reading
    /// release notes / about to click Install would be hostile.
    private func handleSupplementaryTick() async {
        guard let pending = userDriver.pendingItem else {
            Log.app.notice("update: supplementary tick → checkForUpdatesInBackground (no pending)")
            updater.checkForUpdatesInBackground()
            return
        }
        if userDriver.isPopupOpen {
            Log.app.notice("update: supplementary tick — popup open, skipping probe")
            return
        }
        guard let feedURL = Self.appcastFeedURL() else {
            Log.app.error("update: supplementary tick — no SUFeedURL configured, skipping probe")
            return
        }
        let pendingBuild = Int(pending.versionString) ?? 0
        do {
            guard let latestBuild = try await AppcastProbe.probeLatestBuildNumber(feedURL: feedURL) else {
                Log.app.notice("update: probe — no versions parsed, skipping")
                return
            }
            guard latestBuild > pendingBuild else {
                Log.app.notice("update: probe — pending build \(pendingBuild, privacy: .public) is still latest (\(latestBuild, privacy: .public))")
                return
            }
            // Re-check state after the await — the popup may have
            // opened, or the user may have already installed, between
            // when we started probing and now. Bail in those cases.
            guard let stillPending = userDriver.pendingItem,
                  Int(stillPending.versionString) == pendingBuild,
                  !userDriver.isPopupOpen
            else {
                Log.app.notice("update: probe — state changed during await, aborting swap")
                return
            }
            Log.app.notice("update: probe — newer build \(latestBuild, privacy: .public) > pending \(pendingBuild, privacy: .public), swapping offer")
            // `swapForNewerOffer` sends Sparkle the .dismiss reply,
            // which triggers an ASYNC session teardown ending in
            // `dismissUpdateInstallation`. Sparkle drops any
            // checkForUpdatesInBackground call made before the
            // teardown completes (sessionInProgress still true), so
            // the follow-up check is dispatched from
            // dismissUpdateInstallation via runBackgroundCheckAfterSwap().
            userDriver.swapForNewerOffer()
        } catch {
            Log.app.error("update: probe failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func appcastFeedURL() -> URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else { return nil }
        return URL(string: s)
    }

    /// Menu trigger + pill click. Fires an immediate user-initiated
    /// check; Sparkle's reply lands in `PhotoXUserDriver.showUpdateFound`
    /// with `state.userInitiated == true`, which opens the popup.
    /// In DEBUG (Sparkle off) this is a no-op.
    /// Menu / pill entry point. If we still hold a live offer from a
    /// previous showUpdateFound (whether bg poll or user-initiated),
    /// re-open the popup using the cached item — we don't ask
    /// Sparkle for a fresh check because its `.dismiss` memory would
    /// silently no-op same-version checks. Otherwise issue a real
    /// user-initiated check.
    func checkForUpdates() {
        if userDriver.hasPendingOffer {
            Log.app.notice("update: checkForUpdates — replaying cached offer")
            userDriver.openCachedOffer()
            return
        }
        Log.app.notice("update: checkForUpdates() — pendingUserInitiated=true")
        pendingUserInitiated = true
        // Do NOT call updater.resetUpdateCycle() before this — it
        // re-arms the scheduler timer and (empirically) silently
        // cancels the user-initiated check that follows. The
        // documented pattern for user-initiated checks is just
        // `checkForUpdates()`.
        updater.checkForUpdates()
    }

    /// Pill click handler. Same path as the menu item.
    func userClickedAvailable() {
        Log.app.notice("update: pill click")
        checkForUpdates()
    }

    /// Called by `PhotoXUserDriver.dismissUpdateInstallation()` when
    /// Sparkle ends the session (install completed, error, mid-
    /// download cancel). The pill should disappear because there's
    /// no actionable offer left to re-open.
    func clearAvailableUpdate() {
        Log.app.notice("update: clearAvailableUpdate → pill hidden")
        availableUpdate = .none
    }

    /// Set by `PhotoXUserDriver.swapForNewerOffer()` before it sends
    /// `reply(.dismiss)`. Consumed by `updateCycleFinished()` once
    /// Sparkle's delegate confirms session teardown is complete —
    /// that's the only point a follow-up `checkForUpdatesInBackground`
    /// actually runs (verified empirically across two prior attempts:
    /// firing from inside `swapForNewerOffer` or from inside
    /// `dismissUpdateInstallation` both raced ahead of Sparkle's own
    /// `sessionInProgress` reset and got dropped).
    private var pendingProbeRecheck: Bool = false

    func markPendingProbeRecheck() {
        pendingProbeRecheck = true
    }

    /// Wired to `UpdaterDelegate.didFinishUpdateCycleFor`. If we're
    /// the reason this cycle ended (swap triggered it), fire the
    /// follow-up check now.
    func updateCycleFinished() {
        guard pendingProbeRecheck else { return }
        pendingProbeRecheck = false
        Log.app.notice("update: cycle ended → firing post-swap checkForUpdatesInBackground")
        updater.checkForUpdatesInBackground()
    }

    /// Read + reset the "user initiated this check" flag. Called by
    /// `PhotoXUserDriver.showUpdateNotFoundWithError(...)`.
    func consumePendingUserInitiated() -> Bool {
        let v = pendingUserInitiated
        pendingUserInitiated = false
        return v
    }

    // MARK: - Delegate callbacks

    /// Called by `UpdaterDelegate.updaterWillRelaunchApplication`.
    /// Capture the currently-open shoot URL so the post-install
    /// bootstrap can resume it.
    func captureShootForReopen() {
        if let url = shootURLProvider?() {
            PendingReopenStore.set(url: url)
        } else {
            PendingReopenStore.clear()
        }
    }

    /// Called by `PhotoXUserDriver.showUpdateFound(...)` on every
    /// new appcast item — even on background polls — so the pill
    /// always reflects the latest known version.
    func updateDiscovered(item: SUAppcastItem) {
        let version = "v\(item.displayVersionString)"
        Log.app.notice("update: updateDiscovered \(version, privacy: .public) → pill")
        availableUpdate = .available(version: version, item: item)
    }

    /// Called by `UpdaterDelegate.updater(_:didFinishLoadingAppcast:)`
    /// every time Sparkle finishes parsing the feed (each check). The
    /// stashed appcast feeds `PhotoXUserDriver`'s release-notes
    /// aggregator — without this, the popup only shows the target
    /// release's notes even when the user is skipping intermediate
    /// versions.
    func appcastLoaded(_ appcast: SUAppcast) {
        // Log the highest version Sparkle saw — repeated identical
        // values across polls indicate the appcast HTTP response is
        // being cached (Fastly fronts GitHub Raw). The cache-bust
        // timestamp in `UpdaterDelegate.feedParameters` should
        // prevent that; this log confirms.
        let cmp = SUStandardVersionComparator.default
        let latest = appcast.items
            .max { cmp.compareVersion($0.versionString, toVersion: $1.versionString) == .orderedAscending }?
            .displayVersionString ?? "?"
        Log.app.notice("update: appcast loaded with \(appcast.items.count, privacy: .public) items, latest v\(latest, privacy: .public)")
        lastAppcast = appcast
    }

    // MARK: - Pill model

    struct PillContent {
        let icon: String
        let label: String
        let help: String
        let onTap: () -> Void
    }

    /// What the toolbar pill should render. `nil` → hide.
    func pillContent(currentShootURL: URL?) -> PillContent? {
        switch availableUpdate {
        case .none:
            return nil
        case .available(let version, _):
            return PillContent(
                icon: "arrow.down.circle.fill",
                label: "Update available: \(version)",
                help: "Click to install or read release notes.",
                onTap: { [weak self] in self?.userClickedAvailable() }
            )
        }
    }

    private static func clearSkippedVersionDefaults() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "SUSkippedVersion")
        d.removeObject(forKey: "SUSkippedMinorVersion")
    }
}

/// Sparkle's updater-side delegate. Two responsibilities:
///
/// 1. Inject a per-request timestamp into the appcast URL so each
///    check bypasses any CDN/HTTP cache (GitHub Raw is fronted by
///    Fastly).
/// 2. Hook `updaterWillRelaunchApplication` so we can save the
///    currently-open shoot folder URL before Sparkle quits the app
///    for the install — `PhotoXApp.bootstrap` reads it on relaunch.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var controller: UpdaterController?

    nonisolated func feedParameters(for updater: SPUUpdater,
                                    sendingSystemProfile sendingProfile: Bool)
        -> [[String: String]]
    {
        let t = String(Int(Date().timeIntervalSince1970))
        return [["key": "_t", "value": t]]
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Bounce to main actor so we can read SwiftUI state. Capture
        // `self` (an NSObject, not actor-isolated) and reach for the
        // MainActor-isolated `controller` property *inside* the closure
        // — capturing it directly in the capture list would access it
        // from this nonisolated context.
        Task { @MainActor [weak self] in
            self?.controller?.captureShootForReopen()
        }
    }

    /// Called every time Sparkle finishes parsing the appcast feed.
    /// We stash it on the controller so `PhotoXUserDriver` can walk
    /// the full item list when assembling release notes that span
    /// multiple skipped versions.
    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor [weak self] in
            self?.controller?.appcastLoaded(appcast)
        }
    }

    // MARK: - Scheduler-lifecycle diagnostics
    //
    // These three hooks tell us whether Sparkle's scheduler is alive
    // after each update cycle. Without them, "I started the app, no
    // update was found, then I cut a release, then nothing happened"
    // is impossible to distinguish from "Sparkle never re-polled" vs
    // "Sparkle re-polled but the appcast HTTP was cached" vs "the
    // schedule was silently disabled". Cycle-end + arm/disarm events
    // resolve it from `log show`.

    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        let errStr = error.map { String(describing: $0) } ?? "nil"
        Log.app.notice("update: cycle finished kind=\(updateCheck.rawValue, privacy: .public) error=\(errStr, privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater,
                             willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Log.app.notice("update: scheduler armed — next check in \(Int(delay), privacy: .public)s")
        // willScheduleUpdateCheckAfterDelay fires AFTER Sparkle has
        // finished arming its next-tick scheduler — empirically the
        // very last lifecycle hook in a cycle, and the only point
        // where sessionInProgress is definitively false. Firing the
        // post-swap recheck from didFinishUpdateCycleFor was 93µs
        // too early — Sparkle armed the scheduler then dropped the
        // call. From here we're truly past the teardown.
        Task { @MainActor [weak self] in
            self?.controller?.updateCycleFinished()
        }
    }

    nonisolated func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        Log.app.notice("update: scheduler will NOT schedule further checks (auto-checks disabled?)")
    }
}
