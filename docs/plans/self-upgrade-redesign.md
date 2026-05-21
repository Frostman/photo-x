# Self-upgrade redesign: custom 2-button popup with Sparkle under the hood

## Context

Today's self-update UX leaks Sparkle's defaults into PhotoX:

- Click "Check for Updates…" or the titlebar pill → Sparkle shows its
  standard "Update Available" sheet with **Install / Skip Version /
  Remind Me Later** + the "Automatic Updates" toggle.
- The user wants to push aggressively toward updating: only **Cancel
  / Install** should be exposed. No way to skip a version permanently
  and no "later" deferrals.

A previous custom-driver attempt (commit **`92472cd`**) wrapped
`SPUStandardUserDriver` and broke twice — gentle-reminders stopped
firing (pill never appeared) and extraction hung mid-download. That
got reverted in **`8ad0f06`** with the explicit note that wrapping
the standard driver corrupts Sparkle's lifecycle.

This redesign takes the other lane: a **fully custom `SPUUserDriver`**
that implements all 16 protocol methods directly — no inner standard
driver to wrap. We render the entire UI surface ourselves (one popup
window that owns the available → downloading → extracting state
transitions), and forward control back to Sparkle via reply blocks
at the exact lifecycle points it expects.

## Approach

### 1. Replace `SPUStandardUpdaterController` with raw `SPUUpdater` + custom `PhotoXUserDriver`

`UpdaterController` constructs:

```swift
let host = SUHost(bundle: .main)
let userDriver = PhotoXUserDriver(controller: self)
let updater = SPUUpdater(
    hostBundle: .main,
    applicationBundle: .main,
    userDriver: userDriver,
    delegate: updaterDelegate  // existing SPUUpdaterDelegate
)
try? updater.start()
```

`SPUStandardUserDriverDelegate` is no longer needed — gentle-reminders
is what bridges background polls to the pill *only when the standard
driver is active*. With a custom driver, the same routing happens
inside our own `showUpdateFoundWithAppcastItem` implementation
(checking `state.userInitiated`).

### 2. `PhotoXUserDriver` lifecycle dispatch

Per-method behavior. Items marked **CRITICAL** must invoke the
reply/acknowledgement block to keep Sparkle's state machine alive
(this is the lesson from `92472cd` — the previous wrapper missed a
callback during extraction and stalled).

| Method | Our implementation |
|---|---|
| `showUpdatePermissionRequest:reply:` | Auto-decline telemetry, auto-allow checks. **CRITICAL** reply with `SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)`. User never sees this dialog. |
| `showUserInitiatedUpdateCheckWithCancellation:` | Show transient "Checking for updates…" indicator in the popup (or no UI for fast checks). Store the cancel block. |
| `showUpdateFoundWithAppcastItem:state:reply:` | The CORE decision point. If `state.userInitiated` → open popup with version + release notes + Cancel/Install; stash `reply` for the buttons. Else (background poll) → `controller.updateDiscovered(item:)` to flip the pill, then **CRITICAL** `reply(.dismiss)` immediately so Sparkle releases the lock. |
| `showUpdateReleaseNotesWithDownloadData:` | Pass HTML/text to the popup's release-notes view (WKWebView or rendered AttributedString). No callback. |
| `showUpdateReleaseNotesFailedToDownloadWithError:` | Log + show "Release notes unavailable" placeholder. No callback. |
| `showUpdateNotFoundWithError:acknowledgement:` | User-initiated → NSAlert "You're up to date". Background → silent. **CRITICAL** invoke `acknowledgement()`. |
| `showUpdaterError:acknowledgement:` | NSAlert with the error description. **CRITICAL** invoke `acknowledgement()`. |
| `showDownloadInitiatedWithCancellation:` | Popup transitions to "Downloading…" state with progress bar. Store the cancel block — Cancel button now cancels the download. |
| `showDownloadDidReceiveExpectedContentLength:` | Set `totalBytes` for the progress bar denominator. |
| `showDownloadDidReceiveData:` | Increment `receivedBytes`; update progress bar. |
| `showDownloadDidStartExtractingUpdate` | Popup state → "Preparing update…", switch progress bar to indeterminate momentarily. |
| `showExtractionReceivedProgress:` | Update progress bar with extraction fraction. |
| `showReadyToInstallAndRelaunch:` | **AUTO-CONFIRM** — `reply(.install)` immediately. Sparkle's default would otherwise show a second "Install and Relaunch?" sheet; we skip it entirely. **CRITICAL**. |
| `showInstallingUpdateWithApplicationTerminated:retryTerminatingApplication:` | Popup → "Installing…" / app quits in a moment. Don't dismiss the popup; Sparkle terminates the process. Store retry block for the rare relaunch-failure case. |
| `showUpdateInstalledAndRelaunched:acknowledgement:` | Rarely fires (process usually quit). If hit, **CRITICAL** invoke `acknowledgement()`. |
| `dismissUpdateInstallation` | Close the popup window. Clear internal state. |

### 3. Custom popup UI

Single `NSWindowController` hosting a SwiftUI view. Mimics Sparkle's
default look but with a tighter button bar.

```
┌───────────────────────────────────────────────┐
│  [icon]   A new version of PhotoX is available │
│           PhotoX 0.X.0 is now available — you  │
│           have 0.Y.0. Would you like to        │
│           install it?                          │
│                                                │
│   Release notes:                               │
│   ┌──────────────────────────────────────────┐ │
│   │ (scrollable, WKWebView-rendered HTML)    │ │
│   │ • Nav perf fixes...                      │ │
│   │ • Burst features...                      │ │
│   └──────────────────────────────────────────┘ │
│                                                │
│                              [Cancel] [Install]│
└───────────────────────────────────────────────┘
```

State transitions in-place (same window, content swaps):

| Stage | Body | Buttons |
|---|---|---|
| Available | version + release notes | **Cancel** / **Install** |
| Downloading | "Downloading update…" + progress bar (X.X MB / Y.Y MB) | **Cancel** only |
| Extracting | "Preparing to install…" + progress bar | **Cancel** only |
| Installing | "Installing…" + spinner | (none — disabled) |

`Cancel` semantics by stage:
- Available → call stashed `reply(.dismiss)` → close popup → **pill stays visible** with the same version (controller flips `availableUpdate` on the user-initiated `showUpdateFoundWithAppcastItem`, not on click of Install).
- Downloading / Extracting → call stashed download-cancel block → Sparkle aborts → `dismissUpdateInstallation` fires → close popup. Pill stays.

Window stays modal-app-level (`NSWindow.level = .floating`) but
non-blocking so the user can keep using PhotoX while reading release
notes.

### 4. Pill behavior (kept + extended)

`UpdaterController` keeps its `availableUpdate: AvailableUpdate` and
`pillContent(currentShootURL:)` API unchanged. The flips:

- **Background poll finds an update** → `showUpdateFoundWithAppcastItem`
  with `userInitiated == false` → `controller.updateDiscovered(item:)`
  → pill shows version → `reply(.dismiss)`.
- **Background poll finds a NEWER version** (pill already showing
  older) → same hook fires with the newer item → `updateDiscovered`
  overwrites with the new version → pill label updates.
- **User clicks pill** → `controller.userClickedAvailable()` →
  `updater.checkForUpdates()` → `showUpdateFoundWithAppcastItem` with
  `userInitiated == true` → popup opens.
- **User clicks Cancel in popup** → `reply(.dismiss)` → popup closes
  → pill **stays** (the controller's `availableUpdate` was set on
  the background poll OR on the user-initiated hook itself; closing
  the popup doesn't clear it).
- **Install completes** → process quits + relaunches → fresh launch
  re-evaluates `availableUpdate` (.none until next poll, which will
  no longer find an update).

### 5. "Check for Updates" menu — fire an immediate check

Current `checkForUpdates()` already does this:

```swift
updater.updater.resetUpdateCycle()
updater.checkForUpdates(nil)
```

After the swap to raw `SPUUpdater`, this becomes:

```swift
func checkForUpdates() {
    updater.resetUpdateCycle()
    updater.checkForUpdates()
}
```

`checkForUpdates()` is user-initiated by definition — Sparkle sets
`state.userInitiated = true` in the resulting `showUpdateFoundWithAppcastItem`
call. Our driver opens the popup. Same flow as clicking the pill.

### 6. Neutralize any stale "skipped version" state

The previous Sparkle integration could have persisted `SUSkippedVersion`
/ `SUSkippedMinorVersion` in UserDefaults. Since we no longer offer a
Skip button, those keys must not silently suppress updates. On
`UpdaterController.init()`:

```swift
let d = UserDefaults.standard
d.removeObject(forKey: "SUSkippedVersion")
d.removeObject(forKey: "SUSkippedMinorVersion")
```

`SUEnableAutomaticChecks` (5-min background polls) stays on.
`automaticallyDownloadsUpdates` stays **off** — user always chooses
to download via the Install button.

## Critical files to modify / create

| File | Change |
|---|---|
| `PhotoX/Updates/UpdaterController.swift` | Replace `SPUStandardUpdaterController` + `SPUStandardUserDriverDelegate` with raw `SPUUpdater` + `PhotoXUserDriver`. Drop `UserDriverDelegate`. Keep `UpdaterDelegate` (feed parameters + relaunch hook). Add `userClickedInstall()` / `userClickedCancel()` / `userClickedCancelDownload()` for the popup to call. Add `SUSkippedVersion` cleanup in `init()`. |
| `PhotoX/Updates/PhotoXUserDriver.swift` (new) | Implements all 16 `SPUUserDriver` methods per the dispatch table above. Holds strong refs to the popup window controller, stashed reply blocks, and download-cancel block. |
| `PhotoX/Updates/UpdateInstallWindowController.swift` (new) | `NSWindowController` that hosts the SwiftUI popup. Owns the SwiftUI `UpdateInstallView` + an `@Observable` view-model the driver mutates as stages progress. |
| `PhotoX/Updates/UpdateInstallView.swift` (new) | SwiftUI view: version banner, release-notes pane, progress bar, button bar. Reads the view-model; calls back into the driver on button taps. |
| `PhotoX/Updates/UpdateInstallViewModel.swift` (new) | `@Observable` model: `stage: .available / .downloading / .extracting / .installing`, `version: String`, `releaseNotesHTML: Data?`, `totalBytes: UInt64`, `receivedBytes: UInt64`, `extractionProgress: Double`. |
| `PhotoX/Updates/CheckForUpdatesView.swift` | No change. `controller.canCheckForUpdates` is now a mirror of `updater.canCheckForUpdates` (KVO observation moves into `UpdaterController`). |
| `PhotoX/Updates/PendingReopenStore.swift` | No change. Still used by the relaunch-hook to remember the open shoot URL across the install restart. |
| `PhotoX/PhotoXApp.swift` | No change to host wiring. `updater.shootURLProvider` plumbing unchanged. |
| `PhotoX/Info.plist` | No change. `SUEnableAutomaticChecks` + `SUScheduledCheckInterval: 300` stay. |

## Verification

### DEBUG (no Sparkle)

The dev bundle skips Sparkle entirely (`startingUpdater = false` in
`UpdaterController.init`). To exercise the popup UI in dev:

1. Add a DEBUG-only menu item "Show Update Popup (Fake)" that calls
   into `PhotoXUserDriver.previewWithFakeItem(...)` — same view-model
   wiring, no real download. Lets us iterate on the popup look + state
   transitions without shipping a release.
2. Click through each stage manually (Available → Downloading →
   Extracting → Cancel/Install) and confirm:
   - Cancel at Available stage closes window; pill should NOT clear
     (the controller's `availableUpdate` is still set).
   - Cancel during Downloading aborts and returns to no-popup state;
     pill stays.
   - Buttons / progress bar transitions look right.

### Release (real Sparkle path)

The risk is the lifecycle — `92472cd` shipped a release that hung
during extraction. Plan:

1. Cut a release candidate.
2. Publish a *fake* appcast entry pointing to the prior real release
   binary (so we have a "newer version" to find). Example: bump
   `MARKETING_VERSION` in `docs/appcast.xml` to a string greater than
   what the build will report, sign the existing DMG as the asset.
3. Run the install on a clean machine. Verify the full chain works
   end-to-end with NO HANG:
   - Background poll → pill appears.
   - Click pill → popup opens with release notes + version.
   - Click Install → download progress visible → extraction progress
     visible → app quits + relaunches with new version.
   - PendingReopenStore still resumes the open shoot post-relaunch.
4. Verify Cancel paths:
   - Cancel at Available → popup closes, pill stays.
   - Cancel mid-Download → download aborts, popup closes, pill stays.
5. Verify newer-version refresh:
   - Publish v0.X+1.0 to the appcast while the pill shows v0.X.0.
   - Wait 5 min (or click Check for Updates…) → pill label updates
     to v0.X+1.0.
6. Verify "Check for Updates" when already current:
   - Set local version above the appcast → click menu → "You're up to
     date" alert appears via `showUpdateNotFoundWithError`.

### Tests

No new unit tests for the lifecycle (Sparkle internals aren't unit-
testable in isolation), but:

- `UpdateInstallViewModel` is `@Observable` + pure state — covered by
  a small XCTest verifying state transitions on simulated method
  calls.
- A grep-style test: no remaining references to
  `SPUStandardUpdaterController`, `SPUStandardUserDriver`,
  `SPUStandardUserDriverDelegate`, `supportsGentleScheduledUpdateReminders`
  in the codebase.

## Risks

1. **Extraction lifecycle** — primary risk, from `92472cd`'s failure.
   Mitigation: implement every method directly (no wrapping); invoke
   EVERY reply/acknowledgement block (the dispatch table calls them
   out as **CRITICAL**); test on the release path before publishing.
2. **DEBUG can't fully verify** — Sparkle is disabled in dev. The
   fake-popup menu item exercises only the UI, not the Sparkle
   handshake. Acceptable: matches existing dev workflow for
   updater changes ("commit and another release to verify" per
   project memory).
3. **Skipped-version cleanup** — if a user already skipped v0.X.0 via
   the previous Sparkle UI, the new build's `SUSkippedVersion` purge
   will re-offer v0.X.0. Intentional: matches the "push to update"
   goal.
4. **Release notes rendering** — WKWebView in a SwiftUI popup needs
   `NSViewRepresentable` glue. Worst case: render as plain text from
   the appcast description if WKWebView is finicky. Cosmetic only.

## Out of scope

- Auto-download (off by user request).
- A separate "Updates" preferences pane (no settings UI; the user
  asked for no "automatic updates" knob).
- Showing the update size + signature info upfront (Sparkle has it
  but it's noise; the user wants minimal UI).
- Telemetry / SUFeedURL changes — those stay as-is.
