# Self-update pill: replace modal prompts with a titlebar pill

## Context

PhotoX uses Sparkle 2 for auto-updates. The current flow
(`PhotoX/Updates/UpdaterController.swift`) runs a 5-min Sparkle poll
and surfaces every found version through Sparkle's modal "Update
Available" sheet, suppressed between background checks by a custom
in-memory `declinedVersion` lock. That modal interrupts whatever the
user is doing mid-culling, and the sheet's *Skip Version* button can
make a version disappear until the next release.

Goal: replace the interruptive modal with a passive pill in the
window titlebar (leftmost slot, same placement as the existing DEV
pill). The pill announces "Update available: v0.197.0"; click opens
the standard "Install Update" sheet **without** Skip; once Sparkle
has downloaded the update and is awaiting install, the pill flips
to "Restart to install: v0.197.0" — click confirms and relaunches
with the current shoot reopened.

This plan is a refresh of a previously-written design doc. **None of
the redesign is implemented today** — the foundation is there
(Sparkle integration, basic `UpdaterController`, menu's
`CheckForUpdatesView`), the redesign work is from-scratch. The audit
confirmed exact Sparkle 2 method names against
`Sparkle.framework/Headers/SPUUserDriver.h`; method names called out
below are verified.

## Current starting state (verified)

- `UpdaterController.swift` (~155 lines) — uses
  `SPUStandardUpdaterController`, hand-rolled `declinedVersion`
  in-memory lock, no state machine, no observable for the pill.
- `CheckForUpdatesView.swift` — small menu command, fine as-is.
- `PhotoXApp.swift:27` — `@State private var updater: UpdaterController?`
  (nil-able for `-photoxDisableSparkle`); passed only to the menu
  CommandGroup, **not** to `ContentView`.
- `ContentView.swift` toolbar (~lines 255-369) — DEV pill + status
  buttons. No update pill, no UpdaterController param.
- `Info.plist` — `SUFeedURL` (raw.githubusercontent.com),
  `SUScheduledCheckInterval = 300`, `SUEnableAutomaticChecks = true`.
- **Does not exist**: `PhotoXUserDriver.swift`, `PendingReopenStore.swift`,
  pill UI, state machine, gentle-reminder delegate, restart-and-reopen
  flow.

## Sparkle 2 mechanics (verified)

- `SPUUserDriver` protocol (Sparkle/SPUUserDriver.h) — methods we
  must implement or forward:
  - `showUpdatePermissionRequest:reply:` — forward
  - `showUpdateFoundWithAppcastItem:state:reply:` — **override**
    (capture reply, set `availableUpdate = .available(...)`, do NOT
    forward — the pill is the affordance)
  - `showUpdateReleaseNotesWithDownloadData:` — forward
  - `showUpdateReleaseNotesFailedToDownloadWithError:` — forward
  - `showUpdateNotFoundWithError:acknowledgement:` — forward
  - `showUpdaterError:acknowledgement:` — forward
  - `showDownloadInitiatedWithCancellation:` — forward
  - `showDownloadDidReceiveExpectedContentLength:` — forward
  - `showDownloadDidReceiveDataOfLength:` — forward
  - `showDownloadDidStartExtractingUpdate` — forward
  - `showExtractionReceivedProgress:` — forward
  - `showReadyToInstallAndRelaunch:` — **override** (stash reply,
    set `availableUpdate = .readyToInstall(...)`, do NOT forward)
  - `showInstallingUpdate:applicationTerminated:retryTerminatingApplication:` —
    forward
  - `showUpdateInstalledAndRelaunched:acknowledgement:` — forward
  - `dismissUpdateInstallation` — forward
  - `showUpdateInFocus` — forward
- `SPUStandardUserDriverDelegate.supportsGentleScheduledUpdateReminders`
  → return true.
- `SPUStandardUserDriverDelegate.standardUserDriverShouldHandleShowingScheduledUpdate(...)`
  → return false to suppress the modal while still letting Sparkle
  drive into our user-driver's `showUpdateFoundWithAppcastItem...`.

## State machine on `UpdaterController`

```swift
@MainActor
@Observable
final class UpdaterController {
    enum AvailableUpdate: Equatable {
        case none
        case available(version: String, item: SUAppcastItem)
        case readyToInstall(version: String, item: SUAppcastItem)
    }

    private(set) var availableUpdate: AvailableUpdate = .none

    /// Sparkle's reply closure from `showUpdateFoundWithAppcastItem`.
    /// Invoked with `.install` when the user clicks the
    /// `.available` pill (kicks off Sparkle's download UI).
    private var pendingDownloadReply: ((SPUUserUpdateChoice) -> Void)?

    /// Sparkle's reply closure from `showReadyToInstallAndRelaunch`.
    /// Invoked with `.install` after the user OKs the restart alert.
    private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?
    // …
}
```

`version` is `"v\(item.displayVersionString)"`. The pill renders
nothing on `.none`.

## File-by-file plan

### 1. `PhotoX/Updates/UpdaterController.swift` (rewrite)

- Add `@Observable`, the `AvailableUpdate` enum, the two reply slots.
- Replace `SPUStandardUpdaterController` with the lower-level pair:
  ```swift
  private let userDriver: PhotoXUserDriver
  private let updater: SPUUpdater
  init() {
      let standard = SPUStandardUserDriver(hostBundle: Bundle.main,
                                           delegate: nil)
      self.userDriver = PhotoXUserDriver(inner: standard)
      self.updater = SPUUpdater(hostBundle: Bundle.main,
                                applicationBundle: Bundle.main,
                                userDriver: userDriver,
                                delegate: delegate)
      userDriver.controller = self
      standard.delegate = self    // for the gentle-reminders hook
      try? updater.start()
  }
  ```
- Implement `SPUStandardUserDriverDelegate`:
  ```swift
  static var supportsGentleScheduledUpdateReminders: Bool { true }
  func standardUserDriverShouldHandleShowingScheduledUpdate(
      _: SUAppcastItem, andInImmediateFocus: Bool
  ) -> Bool { false }
  ```
- Drop the old `declinedVersion` lock entirely — the user-driver
  swap takes its place.
- Keep the `automaticallyChecksForUpdates = true`,
  `automaticallyDownloadsUpdates = false` policy writes; defensively
  also clear `SUSkippedVersion` at launch so any pre-existing skip
  doesn't permanently silence a version.
- New methods:
  - `userClickedAvailable()` — invoked by the pill's `.available`
    handler. Calls `pendingDownloadReply?(.install)`, sets
    `pendingDownloadReply = nil`. After this, Sparkle drives the
    standard download progress + release-notes UI (forwarded by
    `PhotoXUserDriver`).
  - `confirmRestartAndInstall(currentShootURL: URL?)` — NSAlert
    ("Restart PhotoX to install \(version)? Your current shoot
    will reopen automatically."). On confirm: save the shoot URL
    via `PendingReopenStore.set(url:)` (if non-nil), invoke
    `pendingInstallReply?(.install)`. On cancel: leave state as
    `.readyToInstall` so the pill still offers the choice later.
  - `var pillContent: PillContent?` — `nil` for `.none`, otherwise
    a struct with `icon`, `label`, `onTap`, `help`. Same accent
    background for both states; icons differ:
    - `.available` → `arrow.down.circle.fill`, "Update available: \(version)"
    - `.readyToInstall` → `arrow.clockwise.circle.fill`, "Restart to install: \(version)"

### 2. `PhotoX/Updates/PhotoXUserDriver.swift` (new, ~120 lines)

`@MainActor final class PhotoXUserDriver: NSObject, SPUUserDriver`.
Holds a strong ref to `SPUStandardUserDriver` and a weak/unowned ref
back to `UpdaterController`. Forwards every protocol method to the
inner driver verbatim except the two below.

```swift
func showUpdateFoundWithAppcastItem(_ item: SUAppcastItem,
                                     state: SPUUserUpdateState,
                                     reply: @escaping (SPUUserUpdateChoice) -> Void) {
    controller?.pendingDownloadReply = reply
    controller?.availableUpdate = .available(
        version: "v\(item.displayVersionString ?? item.versionString)",
        item: item)
    // Do NOT forward — pill replaces the standard sheet.
}

func showReadyToInstallAndRelaunch(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
    controller?.pendingInstallReply = reply
    if case .available(_, let item) = controller?.availableUpdate {
        controller?.availableUpdate = .readyToInstall(
            version: "v\(item.displayVersionString ?? item.versionString)",
            item: item)
    }
    // Do NOT forward — pill is the affordance.
}
```

Everything else is `inner.showXyz(...)` pass-throughs. The download-
progress UI, the release-notes panel, the "no update available" and
error paths all keep Sparkle's standard look.

### 3. `PhotoX/Updates/PendingReopenStore.swift` (new, ~40 lines)

```swift
enum PendingReopenStore {
    private static let pathKey = "pendingReopen.path"
    private static let timestampKey = "pendingReopen.timestamp"
    private static let stalenessWindow: TimeInterval = 600  // 10 min

    static func set(url: URL) {
        AppDefaults.shared.set(url.path, forKey: pathKey)
        AppDefaults.shared.set(Date().timeIntervalSince1970, forKey: timestampKey)
    }

    /// Returns + clears the stored URL if it's fresh (< 10 min).
    /// Stale entries are cleared too — a relaunch the next day
    /// shouldn't resurrect yesterday's restart target.
    static func consume() -> URL? {
        let path = AppDefaults.shared.string(forKey: pathKey)
        let ts = AppDefaults.shared.double(forKey: timestampKey)
        clear()
        guard let path, !path.isEmpty,
              Date().timeIntervalSince1970 - ts < stalenessWindow
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func clear() {
        AppDefaults.shared.removeObject(forKey: pathKey)
        AppDefaults.shared.removeObject(forKey: timestampKey)
    }
}
```

Uses `AppDefaults.shared` (same scratch suite under
`-photoxUITestMode`, so the E2E suite stays isolated).

### 4. `PhotoX/ContentView.swift` toolbar (modify)

Add `var updater: UpdaterController?` parameter to the struct (next
to `state`). In `.toolbar`, after the DEV pill, add:

```swift
ToolbarItem(placement: .navigation) {
    if let pill = updater?.pillContent {
        Button(action: pill.onTap) {
            HStack(spacing: 4) {
                Image(systemName: pill.icon)
                Text(pill.label)
            }
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(pill.help)
        .accessibilityIdentifier("toolbar.updatePill")
    }
}
```

`onTap` resolves to either `updater.userClickedAvailable()` or
`updater.confirmRestartAndInstall(currentShootURL: state.shoot?.folderURL)`,
provided by `pillContent` from the controller.

### 5. `PhotoX/PhotoXApp.swift` — bootstrap + wiring (modify)

At the top of `bootstrap()` (currently ~line 109), before the
SamplePathProvider path:

```swift
if let url = PendingReopenStore.consume() {
    await openPath(url.path)
    return
}
```

`openPath` already handles missing folders + empty shoots gracefully.

In the `body` `WindowGroup`, pass `updater` through:
`ContentView(state: viewerState, updater: updater)`.

### 6. `CheckForUpdatesView.swift` (unchanged)

The menu command stays wired to `controller`. Its
`checkForUpdates()` re-enters Sparkle on the user-initiated path —
which means Sparkle calls our user driver's `showUpdateFound...`
path again, populating the pill. The menu still works as a manual
poll trigger.

## Critical files to modify

| File | What changes |
|---|---|
| `PhotoX/Updates/UpdaterController.swift` | Full rewrite: `@Observable`, AvailableUpdate enum, raw SPUUpdater + custom user driver, gentle-reminders delegate, pillContent, userClickedAvailable, confirmRestartAndInstall |
| **`PhotoX/Updates/PhotoXUserDriver.swift`** (new) | SPUUserDriver adapter, forwards all except the two override methods |
| **`PhotoX/Updates/PendingReopenStore.swift`** (new) | UserDefaults wrapper with 10-min staleness |
| `PhotoX/ContentView.swift` | New `updater` param; pill ToolbarItem in `.navigation` slot |
| `PhotoX/PhotoXApp.swift` | bootstrap pre-check, pass updater into ContentView |
| `PhotoXTests/PendingReopenStoreTests.swift` (new) | Round-trip + staleness expiry + clear |

## Reuse / leverage

- `AppDefaults.shared` — same persistence pattern as RecentShoots /
  FavoriteShoots; E2E isolation already handles it.
- `openPath(_:)` in PhotoXApp — already exists, handles missing
  folder / empty shoot. The bootstrap reopen redirect is a one-line
  call.
- `CheckForUpdatesView` — keep as is.
- `LaunchFlags.disableSparkle` (E2E) — keeps the updater nil so
  tests never construct Sparkle; pillContent is nil → ToolbarItem
  renders nothing → no test regression.

## Verification

1. `just build` — clean compile against the local Sparkle headers.
2. `just test` — new `PendingReopenStoreTests` round-trip + 10-min
   expiry pass; existing suite stays green.
3. `just e2e` — full E2E suite still green; the pill never appears
   under `-photoxDisableSparkle YES` (which sets `updater = nil`),
   so toolbar identifier counts unchanged.
4. **Local appcast spoof** (manual, before commit): temporarily
   point `SUFeedURL` in `Info.plist` to a local file URL serving a
   hand-crafted appcast advertising a newer version of an
   already-released DMG. Make a Release build pointed at the
   spoofed feed, install in `/Applications`, launch:
   - Within ~5 s the pill should appear with "Update available:
     v0.<N>.0".
   - No modal should appear at any point during background polling.
   - Click pill → Sparkle's standard Install Update sheet opens.
     Confirm the buttons are *Install Update* / *Remind Me Later* /
     *Release Notes* — **no** Skip Version button.
   - Click *Install Update* — Sparkle's download progress UI shows.
     After download, the standard "Install and Relaunch" sheet must
     NOT appear; instead the pill flips to "Restart to install:
     v0.<N>.0".
   - Click pill → NSAlert confirms restart. Approve. App quits +
     Sparkle installs. On relaunch the same shoot that was open
     before the restart auto-loads.
   - Cancel the restart alert → pill stays as `.readyToInstall`
     so the user can come back to it.
5. **Negative path**: with the feed pointed at the current released
   version, confirm the pill never appears AND no modal is shown.
   Trigger "Check for Updates…" from the menu — the user-initiated
   "no updates available" sheet still surfaces (we keep the
   standard driver for that path via forwarding).
6. **Stale reopen path**: kill the app between
   `PendingReopenStore.set` and a clean install by force-quitting.
   Relaunch — `bootstrap` should fall through to the
   SamplePathProvider path (consume returned nil because of the
   staleness check OR cleared keys), no crash.

Hand off to user for the spoofed-appcast manual test before
committing per the user-confirms-before-commit rule.

## Out of scope / follow-ups

- No Settings UI for auto-update — `automaticallyDownloadsUpdates`
  stays hardcoded `false`. Revisit if requested.
- No telemetry on pill clicks.
- No persistent "last-seen version" cache — Sparkle re-calls the
  driver on each background poll, so the pill rebuilds organically.
- Per-restart "what's new" inline panel — Sparkle's standard
  release-notes UI suffices; revisit if users want it inline.
