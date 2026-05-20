# Self-update pill: replace modal prompts with a titlebar pill

## Context

The current self-update flow (`PhotoX/Updates/UpdaterController.swift`)
runs a 5-min Sparkle poll and surfaces every found version through
Sparkle's modal "Update Available" sheet. A custom in-memory
`declinedVersion` lock suppresses re-prompting between background
checks, but the modal still interrupts whatever the user is doing
during culling, and the standard sheet's *Skip Version* button can
make a version disappear until the next release.

Goal: replace the interruptive modal with a passive pill in the
window titlebar (leftmost slot — same placement as the existing DEV
pill). The pill announces "Update available: v0.197.0", click opens
the standard "Install Update" sheet (Skip button hidden), and once an
update has been downloaded and is awaiting install the pill flips to
"Restart to install: v0.197.0" — click confirms and relaunches into
the new version with the current shoot reopened.

Existing users get the new behavior unconditionally on first launch
after upgrade (we force-write Sparkle's user-defaults policy keys at
startup; the new launch path also wipes any stale skip-version state).

## Sparkle mechanics recap (so the design is grounded)

- Sparkle never live-patches. With `automaticallyDownloadsUpdates =
  false` (our policy), the user must click through a sheet to
  download. Once downloaded, the install runs at app quit; relaunch
  brings up the new bundle. No in-place hot-swap exists.
- Sparkle 2 ships a "gentle scheduled update reminders" hook on
  `SPUStandardUserDriverDelegate`: setting
  `supportsGentleScheduledUpdateReminders = true` and returning
  `false` from `standardUserDriverShouldHandleShowingScheduledUpdate`
  suppresses the modal while still calling
  `standardUserDriverWillHandleShowingUpdate`. That's our pill's
  signal source.
- The Skip button is not toggleable via the standard delegate. To
  hide it we wrap `SPUStandardUserDriver` in a custom `SPUUserDriver`
  that forwards every method except `showUpdateFound...`, which we
  reimplement against `NSAlert` with only "Install Update" and "Not
  Now" buttons.

## State machine on `UpdaterController`

```swift
enum AvailableUpdate: Equatable {
    case none
    case available(version: String, item: SUAppcastItem)
    case readyToInstall(version: String, item: SUAppcastItem)
}
```

`version` is `item.displayVersionString` formatted as `v\(displayVersionString)`.
The pill renders nothing when `.none`, and the click handler dispatches
on the case.

A separate `private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?`
holds Sparkle's reply closure when the user driver receives the
"ready to install and relaunch" callback. Click-to-restart invokes it
with `.install`.

## File-by-file plan

### 1. `PhotoX/Updates/UpdaterController.swift` (modify)

- Replace the `declinedVersion`-lock policy block with an
  `@Observable` `availableUpdate: AvailableUpdate = .none` plus the
  `pendingInstallReply` slot.
- `UpdaterDelegate` (the `SPUUpdaterDelegate`) keeps the
  `feedParameters` cache-buster but loses `userDidMake` and
  `shouldProceedWithUpdate` (the modal it suppressed is gone).
- Instantiate `SPUStandardUpdaterController` with `userDriver:` set
  to our new `PhotoXUserDriver` (see #2). That requires using the
  `init(updater:userDriverDelegate:)`-style construction (raw
  `SPUUpdater` + custom user driver) rather than the standard
  controller's all-in-one initializer.
- `confirmRestartAndInstall(currentShootURL:)` — public method
  invoked by the pill click in `.readyToInstall`. Shows an
  `NSAlert` ("Restart PhotoX to install v0.197.0? Your current
  shoot will reopen automatically."). On confirm, writes the shoot
  URL via `PendingReopenStore.set(url:)` (see #4) and invokes
  `pendingInstallReply?(.install)`.
- `checkForUpdates()` keeps the cache-bust + `resetUpdateCycle`
  dance.

### 2. `PhotoX/Updates/PhotoXUserDriver.swift` (new)

A thin `SPUUserDriver` adapter:

- Strong-holds an `SPUStandardUserDriver` instance and forwards every
  protocol method to it **except**:
  - `showUpdateFoundWithAppcastItem:state:reply:` — instead of
    handing off to the standard driver (which would show its
    three-button sheet), capture the `reply` closure onto
    `UpdaterController`, set `availableUpdate = .available(...)`,
    and DO NOT call the inner driver yet. The pill is now the
    affordance; click invokes the saved reply.
  - `showReadyToInstallAndRelaunch:reply:` (or whichever
    name in Sparkle 2 matches; verify against the local Sparkle
    headers during implementation) — stash the reply as
    `pendingInstallReply`, set `availableUpdate = .readyToInstall(...)`,
    swallow the call so the standard "install + relaunch now?"
    sheet never shows.
  - The "user clicked the pill (available)" path: a method on
    `UpdaterController` that invokes the stashed `.install` reply,
    *then* forwards the next `showDownloadInitiated…`,
    `showDownloadDidReceiveData…`, etc. callbacks to the inner
    standard driver — so Sparkle's stock download-progress and
    release-notes UI still appears between click and install.
- All other protocol methods forward verbatim. Crucially: the
  download-progress window, the release-notes panel, and the
  "no update available" + error paths all stay Sparkle's standard
  UI. We only replace the two "is there a Skip button?" surfaces.

Implementation note: the simplest forwarding pattern is to make
`PhotoXUserDriver` a small `NSObject` conforming to `SPUUserDriver`
and call `standardDriver.<method>(...)` in each method body. Sparkle's
protocol surface is ~12 methods; this is ~80 lines plus the two
overridden alerts.

### 3. `PhotoX/ContentView.swift` (modify, ~lines 272–298)

In the `.toolbar` block, immediately **after** the DEBUG-only DEV
pill, add a `ToolbarItem(placement: .navigation)` that renders only
when `updaterController.availableUpdate != .none`:

```swift
ToolbarItem(placement: .navigation) {
    if let pill = updateController?.pillContent {
        Button(action: pill.onTap) {
            HStack(spacing: 4) {
                Image(systemName: pill.icon)
                Text(pill.label)
            }
            .font(.caption.bold())
            .foregroundStyle(pill.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(pill.background, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(pill.help)
    }
}
```

`pillContent` is a small struct computed on `UpdaterController` from
`availableUpdate`:

- `.available(version, _)` → icon `arrow.down.circle.fill`, label
  "Update available: \(version)", tap = `checkForUpdates()` (which
  triggers Sparkle's stock Install Update sheet — without Skip,
  because of the user driver swap).
- `.readyToInstall(version, _)` → icon `arrow.clockwise.circle.fill`,
  label "Restart to install: \(version)", tap =
  `confirmRestartAndInstall(currentShootURL: state.shoot?.folderURL)`.

Tinting matches the existing DEV pill's restrained palette but with a
neutral blue (system `accentColor`) so it doesn't read as a warning.
`ContentView` needs to receive the `UpdaterController` — pass it
through `PhotoXApp` like `viewerState` is passed.

### 4. `PhotoX/Updates/PendingReopenStore.swift` (new)

Tiny wrapper around `UserDefaults` with two keys:
- `PendingReopenShootURL` — file URL string
- `PendingReopenTimestamp` — unix epoch seconds

```swift
enum PendingReopenStore {
    static func set(url: URL) { ... }
    static func consume() -> URL? // returns + clears if <10 min old
    static func clear() { ... }
}
```

Stale entries (>10 min) are dropped on read — guards against a
crashed install leaving a stale reopen target behind.

### 5. `PhotoX/PhotoXApp.swift` `bootstrap()` (modify, ~line 109)

At the top of `bootstrap()`, before the `SamplePathProvider` path:

```swift
if let url = PendingReopenStore.consume() {
    await openPath(url.path)
    return
}
```

`openPath` already exists at line 132 and handles missing folders /
empty shoots gracefully, so this is a one-line redirect.

### 6. `PhotoX/PhotoXApp.swift` (modify, near line 27)

Wire `UpdaterController` through to `ContentView` (it's already
constructed; just pass the reference). One extra parameter.

## Behaviors covered

| Requirement | Where it's satisfied |
|---|---|
| Periodic check | Existing `SUScheduledCheckInterval = 300` in Info.plist |
| No modal popup on detect | `supportsGentleScheduledUpdateReminders` + `standardUserDriverShouldHandleShowingScheduledUpdate` returning false |
| Pill leftmost in titlebar | `ToolbarItem(placement: .navigation)` added in `ContentView.swift` |
| Pill text shows short version (no sha) | `SUAppcastItem.displayVersionString` (already the marketing version) |
| Click pill → standard install sheet | `checkForUpdates()` re-enters Sparkle on user-initiated path |
| Skip button hidden | Custom `PhotoXUserDriver` reimplements the "update found" alert without it |
| Newer version → pill updates | Each `standardUserDriverWillHandleShowingUpdate` call overwrites `availableUpdate` |
| "Restart required" pill state | New `.readyToInstall` case, populated when Sparkle calls `showReadyToInstallAndRelaunch:` |
| Confirm before restart | `NSAlert` in `confirmRestartAndInstall` |
| Reopen same shoot post-restart | `PendingReopenStore` + `bootstrap()` redirect |
| Existing-user upgrade path | Existing force-write of `automaticallyChecksForUpdates = true` / `automaticallyDownloadsUpdates = false` on every launch + new launch wipes `SUSkippedVersion` (defensive — shouldn't be reachable post-redesign but defends against pre-upgrade state) |

## Things deliberately NOT done

- **No Settings UI for auto-update.** Toggle stays hidden;
  `automaticallyDownloadsUpdates` is hardcoded `false` (existing
  policy). Future revisit if requested.
- **No telemetry** on pill clicks. We can add it later if useful.
- **No persistent "last seen version" state.** The pill rebuilds from
  Sparkle's gentle-reminder callbacks on every launch — Sparkle will
  re-call us on the next scheduled or immediate check after launch.

## Verification

End-to-end with the real Sparkle path:

1. **Build the dev binary**: `just build`. The DEV build has Sparkle
   disabled (`startingUpdater = false`), so the pill won't fire — but
   the build must compile cleanly and `UpdaterController` must
   resolve symbols against the local Sparkle headers.
2. **Local appcast spoof**: temporarily edit `SUFeedURL` in Info.plist
   to a local file URL serving a hand-crafted appcast advertising a
   newer version of an already-released DMG. Make a Release build
   pointed at this spoofed feed. Launch and:
   - Within ~5 sec the pill should appear with "Update available:
     v0.197.0" (or whatever version the spoofed feed advertises).
   - No modal sheet should appear at any point.
   - Click pill → standard Install Update sheet opens. Confirm the
     three buttons are *Install Update* / *Remind Me Later* /
     *Release Notes* — **no** Skip Version button.
   - Click *Install Update*. Progress UI is Sparkle's standard. After
     download, the standard "Install and Relaunch" sheet must NOT
     appear; instead the pill should flip to "Restart to install:
     v0.197.0".
   - Click the pill → NSAlert confirms restart. Approve. App quits
     and Sparkle installs. On relaunch, the same shoot that was open
     before the restart should auto-load.
3. **Stale shoot path**: kill the app between `PendingReopenStore.set`
   and a clean install by force-quitting. Relaunch — bootstrap should
   not crash if the saved folder is missing (covered by `openPath`'s
   existing fallback) and the pending entry should be cleared.
4. **Negative path**: with the feed pointed at the *current* released
   version (no update available), confirm the pill never appears and
   no modal is shown. After clicking Check for Updates from the menu,
   confirm the user-initiated "no updates available" sheet still
   surfaces (we keep the standard driver for that path).
5. **Unit-test surface**: add a small test that
   `PendingReopenStore.consume()` returns nil after 10 min and
   clears the keys after returning a fresh URL. (`PhotoXTests/`.)

Hand off to user for the spoofed-appcast manual test before committing.
