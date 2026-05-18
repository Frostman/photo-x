# Phase 4 — Export to Multiple Destinations

## Context

Culling is only valuable if the final selection moves out of PhotoX into the next step (delivery folder, Lightroom catalog, backup drive). Today, the user picks star/label/reject in PhotoX and then manually copies files in Finder, applying filters by eye. This phase adds an in-app **Export** pipeline: configure a list of destinations, give each one its own rating filter + file-type toggles + overwrite policy, and copy matching pairs there in one click — optionally pruning files that no longer match.

The whole thing is **backgroundable**: close the sheet during a long export and the toolbar shows a live progress pill that reopens the window on click.

## Decisions locked in

| Area | Decision |
|---|---|
| Persistence | `ExportSettings` singleton (project name + destinations) using the `FavoriteShoots` pattern (JSON-encoded into UserDefaults). One project name + destinations list, global across all shoots. |
| Project name | Becomes a **subfolder** under each destination: `<dest>/<project>/<stem>.{arw,hif,xmp}`. Empty project name = copy directly into `<dest>/`. |
| File-type toggles | **Per-destination** (ARW, HIF, XMP). Default: all on. |
| Per-destination filter | Identical to the status-bar row: `★1..★5` + `✗` + `○`. Default: all on. |
| Overwrite policy | **Per-destination** picker, four options: `skip if same size + mtime ≤1s, else overwrite` (default) / `skip if same size + mtime ≤1s, else only copy if source newer` / `always skip if exists` / `always overwrite`. |
| Orphan removal | **Per-destination** toggle. When on: after the copy phase, delete files in the destination subfolder whose stem isn't in the filtered set. Confirmation dialog at the start of each run that has it enabled. |
| Drag-to-reorder | Identical UX to starter-screen favorites (`line.3.horizontal` handle, accent capsule insertion indicator). |
| Per-destination run | Each row has a Run button that exports only that destination. |
| "Export all" | Sequential, one destination at a time. Avoids IO contention; makes per-dest progress meaningful. |
| Backgroundable | Sheet can close mid-export; runner keeps going; toolbar pill shows live state. Click pill to reopen the sheet. |
| Progress UI | Per-destination progress bar + ETA, plus overall progress bar + ETA at the bottom of the sheet. Cancel button (global + per-destination). End-of-run summary: copied / skipped / errored. |
| Toolbar pill | Sits to the LEFT of the existing right-side button cluster, visually separated. Idle: `arrow.up.doc` + "Export". Running: spinner / progress indicator + "Export 47%" + ETA. Always clickable → opens sheet. |
| Activation | Toolbar Export pill only appears when `state.shoot != nil` AND (the export sheet is available OR an export is running). |
| Project name required | **Empty project name is rejected.** Export and Run buttons stay disabled until a non-empty name is set; a placeholder hint reads "Required to export". Trimmed of whitespace before validation. |
| Read-once / write-many | Optional global checkbox in the sheet: "Read each file once, write to all destinations" (default OFF). When ON, the **Export all** path uses a single read per source file and fans out writes to every destination that wants it (saves IO on slow source drives — SD card readers especially). Per-destination Run buttons always use the simple per-destination loop. |
| Close Folder while running | The Close Folder toolbar button is **disabled** while `ExportRunner.isRunning`, with a help tooltip explaining why. |
| App-quit guard | If the user tries to quit / ⌘Q / close window during a run, intercept in `applicationShouldTerminate` and present an alert: **"Export in progress — cancel and quit, or stay?"** Requires an extra confirmation tap (destructive button styling) so it can't be dismissed by reflex. |
| Notifications | After each destination finishes (success or failure), schedule a macOS `UNNotification` "Export to <basename> complete (N copied, M skipped)." — EXCEPT the last destination in an "Export all" run. After the whole run finishes, schedule a single "All exports finished" summary notification. Single-destination Run posts one notification on completion. |

## Top-level UI

```
┌────────────────────────────────────────────────────────────────────────────┐
│  Title bar                                                                 │
│                                                                            │
│  [Export 47%  •  3m]    [Open  Close  ☀  ⚙  ?  ⬛  ⬛]                       │
│   ←── export pill ──→    ←── existing right cluster (unchanged) ──→        │
└────────────────────────────────────────────────────────────────────────────┘

Export Sheet (modal over main window, dismissable while running):
┌──────────────────────────────────────────────────────────────────────────┐
│  Export                                                  ×              │
│                                                                          │
│  Project name [_____________________________________]                    │
│  Files land at <destination>/<project name>/                             │
│                                                                          │
│  Destinations                                       [+ Add destination]  │
│  ────────────────────────────────────────────────────────────────────── │
│  ≡  📁 ~/Pictures/Delivery/Weddings                  [▶ Run]  [⋯]  [×]   │
│     ★1 ★2 ★3 ★4 ★5  ✗ ○      ARW HIF XMP            Overwrite ▾  □ prune │
│     ──────────────────────                                                │
│     Progress: ████████░░░░░░░░  47%   ETA 1m 20s    320/680 pairs        │
│                                                                          │
│  ≡  📁 /Volumes/Backup/RAW                           [▶ Run]  [⋯]  [×]   │
│     ★1 ★2 ★3 ★4 ★5  ✗ ○      ARW HIF ─              Overwrite ▾  □ prune │
│     Idle                                                                  │
│                                                                          │
│  ≡  📁 ~/Dropbox/Shared/Web                          [▶ Run]  [⋯]  [×]   │
│     ─ ─ ★3 ★4 ★5  ─ ─        ─ HIF XMP              Overwrite ▾  ☑ prune │
│     ⚠ Orphan removal enabled    Idle                                     │
│                                                                          │
│  ────────────────────────────────────────────────────────────────────── │
│  Overall: ██░░░░░░░░░░░░░░  12%   ETA 4m 30s                              │
│                                                                          │
│  [Cancel all]                              [Close]      [▶ Export all]   │
└──────────────────────────────────────────────────────────────────────────┘
```

## Architecture

Two new types:

### 1. `ExportSettings` (persistent, configuration)

`@MainActor @Observable` singleton, JSON-encoded into UserDefaults. Same shape as `FavoriteShoots`/`RecentShoots`.

```swift
@MainActor
@Observable
final class ExportSettings {
    static let shared = ExportSettings()

    struct Destination: Identifiable, Codable, Hashable, Sendable {
        var id: UUID = UUID()
        var path: String

        // Filter (same semantics as ViewerState.show*)
        var showStars: Set<Int> = [1, 2, 3, 4, 5]
        var showRejected: Bool = true
        var showUnrated: Bool = true

        // File types
        var includeARW: Bool = true
        var includeHIF: Bool = true
        var includeXMP: Bool = true

        // Behaviour
        var overwrite: OverwritePolicy = .skipUnchangedElseOverwrite
        var removeOrphans: Bool = false
    }

    enum OverwritePolicy: String, Codable, CaseIterable, Identifiable {
        case skipUnchangedElseOverwrite   // default
        case skipUnchangedElseNewerOnly
        case skipIfExists
        case alwaysOverwrite

        var id: String { rawValue }
        var displayName: String { ... }
    }

    var projectName: String = ""
    var destinations: [Destination] = []

    func add(path: String) { ... }
    func remove(id: UUID) { ... }
    func update(id: UUID, _ mutate: (inout Destination) -> Void) { ... }
    func move(_ id: UUID, before targetID: UUID) { ... }
}
```

### 2. `ExportRunner` (in-flight state, copy engine)

`@MainActor @Observable` singleton — separate from settings because lifetime differs (settings live forever, a run is transient). Holds per-destination + overall progress, exposes start/cancel methods. Used by both the sheet and the toolbar pill.

```swift
@MainActor
@Observable
final class ExportRunner {
    static let shared = ExportRunner()

    enum DestinationState: Sendable {
        case idle
        case queued
        case running(Progress)
        case done(Summary)
        case cancelled
        case failed(String)
    }

    struct Progress: Sendable {
        let copied: Int          // files done (counts ARW+HIF+XMP separately)
        let skipped: Int
        let total: Int           // files to attempt
        let bytesCopied: Int64
        let totalBytes: Int64
        let currentFilename: String?
        let startedAt: Date

        var percent: Double { Double(bytesCopied) / max(1, Double(totalBytes)) }
        var eta: TimeInterval? { ... }   // (totalBytes - bytesCopied) / rate
    }

    struct Summary: Sendable {
        let copied: Int; let skipped: Int; let deleted: Int; let errors: [(String, String)]
        let elapsed: TimeInterval
    }

    private(set) var perDestination: [UUID: DestinationState] = [:]
    var overallProgress: Progress? { ... }   // combined across .running destinations

    var isRunning: Bool { perDestination.values.contains { if case .running = $0 { true } else { false } } }

    // pair-source must be supplied: ExportRunner doesn't own the shoot.
    func startAll(pairs: [PhotoPair], pairXMPs: [String: XMPSidecar],
                  projectName: String, destinations: [ExportSettings.Destination]) async { ... }
    func startOne(_ destinationID: UUID, pairs: [PhotoPair], pairXMPs: [String: XMPSidecar],
                  projectName: String, destination: ExportSettings.Destination) async { ... }
    func cancelAll() { ... }
    func cancel(_ destinationID: UUID) { ... }
}
```

Pair filtering inside `ExportRunner` reuses `ViewerState.RatingCategory` semantics — duplicate the tiny `ratingCategory` + match function (3 lines) to avoid coupling the runner to ViewerState.

### Copy loop — two modes

Both modes share the **decision function**:

```swift
enum CopyDecision { case skip, write(removeFirst: Bool) }

func decide(srcURL: URL, destURL: URL, isXMP: Bool,
            policy: OverwritePolicy) -> CopyDecision {
    let srcAttrs = stat(srcURL)
    guard let destAttrs = try? stat(destURL) else {
        return .write(removeFirst: false)   // dest doesn't exist
    }
    // Universal: same size + mtime within 1s ⇒ skip
    if srcAttrs.size == destAttrs.size,
       abs(srcAttrs.mtime.timeIntervalSince(destAttrs.mtime)) < 1.0 {
        return .skip
    }
    // XMP-only rule that ALWAYS applies: never regress a newer sidecar
    if isXMP, destAttrs.mtime > srcAttrs.mtime {
        return .skip
    }
    switch policy {
    case .alwaysOverwrite:              return .write(removeFirst: true)
    case .skipIfExists:                 return .skip
    case .skipUnchangedElseOverwrite:   return .write(removeFirst: true)
    case .skipUnchangedElseNewerOnly:
        return srcAttrs.mtime > destAttrs.mtime ? .write(removeFirst: true) : .skip
    }
}
```

#### Mode A — per-destination loop (simple, default; also used by per-destination Run buttons)

```
For each destination D in run-set, sequentially:
  1. Resolve outputFolder = D.path/<projectName>; mkdir -p.
  2. Filter pairs through D's filter → eligible pairs.
  3. Build file list: for each eligible pair, include ARW/HIF/XMP per D's toggles.
  4. Compute totalBytes (sum of src sizes).
  5. For each src file:
       decision = decide(src, dest, isXMP, D.overwrite)
       if .write(removeFirst:) → optionally remove, then FileManager.copyItem
       if .skip → bump skipped counter
       update progress + currentFilename
       break on Task.isCancelled
  6. If D.removeOrphans: list outputFolder, delete files whose stem ∉ eligible set.
  7. Emit per-destination Summary; post notification (unless this is the last
     destination in an Export-all batch).
After loop: post "All exports finished" notification.
```

#### Mode B — read-once / write-many (Export all + flag on)

```
Precompute, for each pair × file-type, the list of destinations that:
  (a) want this file type, and
  (b) pass the per-destination filter for this pair, and
  (c) the per-destination overwrite decision is .write (not .skip).

Build: writes: [PairFileKey: [DestinationID: URL]]
Skip plans for .skip cases are tallied into each destination's Progress upfront.

For each src file with at least one destination wanting a write:
  read = Data(contentsOf: src)   // single read
  for (destID, destURL) in writes[key]:
    optionally remove(destURL)
    try data.write(to: destURL, options: .atomic)
    update that destination's progress
On cancel: bail between files (atomic.write means a partial run won't leave
half-written destinations from THIS file, but earlier files stay copied).

After per-file phase: per-destination orphan-removal phases run sequentially
(orphans are per-destination, can't be batched).
```

The decision function runs once per (file, destination) pair in both modes; only the *order* of writes differs. Result is byte-identical and tests can be written to assert that for fixture inputs.

### Toolbar pill

A custom `View` in the toolbar that renders one of two looks based on `ExportRunner.shared.isRunning`:

- **Idle**: `Button { showExportSheet = true } label: { Label("Export", systemImage: "arrow.up.doc") }` styled as a pill. (Looks like the existing toolbar buttons.)
- **Running**: A larger pill with a circular `ProgressView(value:)` + "Export 47%" + small ETA text. Click reopens the sheet.

Placement: insert as the FIRST `.primaryAction` (leftmost in the right cluster) with a `Divider()` after it for visual separation. macOS toolbars don't natively support two distinct "pill" groups, but a divider sells the visual split.

Gating: only present when `state.shoot != nil` (so the starter screen stays clean) OR when `ExportRunner.shared.isRunning` (so the pill stays visible even if the user closes the shoot mid-export — they need to see it finish).

### Quit guard

`AppDelegate.applicationShouldTerminate(_:)`:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard ExportRunner.shared.isRunning else { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = "Export in progress"
    alert.informativeText = "An export to one or more destinations is still running. Quitting now will cancel it and leave partially-copied files at the destinations."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Stay")               // first = default = ⏎
    let cancelBtn = alert.addButton(withTitle: "Cancel exports and quit")
    cancelBtn.hasDestructiveAction = true            // red styling, requires deliberate click
    let response = alert.runModal()
    if response == .alertSecondButtonReturn {
        ExportRunner.shared.cancelAll()
        return .terminateNow
    }
    return .terminateCancel
}
```

The "Close Folder" toolbar button is `.disabled(ExportRunner.shared.isRunning)` with help text "Cannot close while an export is running."

### Notifications (`UserNotifications`)

```swift
@MainActor
enum ExportNotifications {
    static func requestAuthorizationIfNeeded() async { ... } // call once on first run
    static func postDestinationComplete(_ dest: ExportSettings.Destination,
                                        summary: ExportRunner.Summary) { ... }
    static func postAllComplete(totalCopied: Int, totalSkipped: Int, elapsed: TimeInterval) { ... }
}
```

`ExportRunner` calls into `ExportNotifications` at the right moments:
- Single-destination Run completion → one `postDestinationComplete`.
- Export-all: after each destination except the last → `postDestinationComplete`. After the run as a whole → `postAllComplete`.

Authorization is requested lazily (first time an export completes) so the user isn't pinged at app launch.

## File layout

```
PhotoX/Export/
  ExportSettings.swift          # singleton + Destination + OverwritePolicy
  ExportRunner.swift            # singleton + decision fn + Mode A/B copy loops
  ExportNotifications.swift     # UNUserNotificationCenter wrappers
  ExportSheet.swift             # main popup
  ExportDestinationRow.swift    # one row (handle, filter, types, run, etc.)
  ExportToolbarPill.swift       # toolbar button that doubles as progress display

PhotoX/ContentView.swift        # CHANGED: add ExportToolbarPill to toolbar, host the sheet
                                # CHANGED: disable Close Folder while exporting
PhotoX/PhotoXApp.swift          # CHANGED: applicationShouldTerminate quit guard
PhotoX/Model/ViewerState.swift  # unchanged (export reads pairs + pairXMPs as plain data)
```

## Tests — extensive (PhotoXTests, no GPU/network)

Export is one of the most consequential features (touches the user's files; mistakes are silent data loss). Aim for >90% line coverage of `Export/`, with explicit table-driven coverage of the decision matrix.

### A. `ExportSettingsTests` (10 tests, ~150 LOC)
- `init_emptyDefaults` — fresh suite yields empty destinations + empty project name.
- `roundTrip_destinations_persistsJSON` — add several with mixed filter states, re-init from same defaults → identical list.
- `add_appendsAtEnd_setsFreshUUID`.
- `remove_byID_persists`.
- `update_byID_mutateCallback_persists`.
- `move_before_reorders_andPersists` — table of 5 (from, to) cases including from<to, from>to, no-op, missing IDs.
- `projectName_setAndPersist`.
- `projectName_trimmedAndRejectedWhenEmpty` — assert that `isValidForExport(projectName:)` returns false for `""`, `"   "`, `"\n"`.
- `destinationDefaults_areReasonable` — new destination has all stars/rejected/unrated on, all file types on, `skipUnchangedElseOverwrite`, `removeOrphans=false`.
- `userDefaultsIsolation` — uses a `UserDefaults(suiteName:)` per test so the user's real settings aren't touched (mirrors `RecentShootsTests`).

### B. `OverwriteDecisionTests` (24+ tests, pure function table)
4 policies × 6 file states. State columns: `dest exists?`, `same size?`, `mtime delta < 1s?`, `src newer?`. For each policy:
| dest | same size | mtime <1s | src newer | Expected |
|---|---|---|---|---|
| no | — | — | — | write |
| yes | yes | yes | — | skip (universal) |
| yes | no | yes | yes | write |
| yes | no | yes | no | (per policy) |
| yes | yes | no | yes | (per policy) |
| yes | yes | no | no | (per policy) |
- 24 base cases × 4 policies = comprehensive matrix.
- Separately: 6 XMP-specific cases verifying the "never overwrite newer XMP" rule kicks in regardless of policy (e.g. `alwaysOverwrite` + XMP + dest newer → skip).

### C. `ExportCopyLoopTests` (~12 tests against a temp dir)
For each test: synthesise a tiny shoot in a tmp source dir (3–5 stems, each with `.arw`/`.hif`/`.xmp` empty-but-real files), a tmp destination dir, and a destination config; run; assert directory contents.
- `copy_emptyDestination_copiesAllMatchingPairs`.
- `copy_respectsFilter` — set `showStars = [5]`; only 5-star pair files copied.
- `copy_respectsTypeToggles` — `includeXMP = false`; XMP files absent at dest.
- `copy_projectSubfolder_created` — project name "Wedding"; files at `<dest>/Wedding/<stem>...`.
- `copy_existingMatching_isSkipped` — copy twice; second run reports all skipped, mtimes unchanged.
- `copy_existingMismatch_overwrites_per_policy` — table: each of 4 policies vs a dest file with stale content. Verify the file is/isn't overwritten and the bytes match.
- `copy_xmp_newerAtDest_isNeverRegressed` — set dest XMP to 1 hour in the future. Use `alwaysOverwrite` policy. Assert dest XMP unchanged.
- `copy_removeOrphans_deletesPairsThatFellOut` — pre-populate dest with stems A, B, C. Run with filter showing only A. Assert B and C deleted.
- `copy_removeOrphans_doesNotDeleteForeignFiles` — pre-populate dest with `unrelated.txt`. Assert it survives (orphan removal only deletes files whose stem matches the ARW/HIF/XMP pattern).
- `copy_handlesMissingSrcFiles_gracefully` — pair missing its XMP file → copies ARW+HIF, no error.
- `copy_handlesPermissionError_recordedInSummary` — make dest read-only; assert summary lists the error and continues to next file.
- `copy_cancellation_stopsBetweenFiles` — start, immediately cancel; assert partial dir contents + `.cancelled` state.

### D. `ExportRunnerStateTests` (~8 tests)
- `startAll_setsAllToQueued_thenRunningSequentially`.
- `startOne_doesNotTouchOtherDestinations`.
- `runner_isRunning_truthWhileAnyRunning`.
- `cancelAll_movesAllToCancelled`.
- `cancel_singleDestination_doesNotAffectOthers`.
- `overallProgress_sumsAcrossRunningDestinations`.
- `eta_extrapolatesFromObservedRate`.
- `summary_perDestination_recordsCopiedSkippedDeletedErrored`.

### E. `ExportReadOnceModeTests` (~5 tests)
- `modeB_producesByteIdenticalResultToModeA` — set up 2 destinations + 5 pairs; run with flag off and once with flag on into separate dest trees; recursively diff (file hashes). Same result.
- `modeB_singleRead_per_source_file` — instrument the copy to count reads; assert each unique source file is read exactly once even when 3 destinations want it.
- `modeB_skipsDoNotForceRead` — if all 3 destinations would skip this file (per decision), no read happens.
- `modeB_atomicWritesEachDestination` — kill the process mid-run; assert no partially-written destination files (atomic temp+rename).
- `modeB_orphanPhase_perDestination_still` — orphan removal still runs per-destination at the end.

### F. `ExportNotificationsTests` (~4 tests, mock UNUserNotificationCenter)
- `singleDestRun_postsOneCompletion`.
- `exportAll_postsAfterEachDestExceptLast_plusFinalSummary` — 3 dests, expect 2 + 1 = 3 notifications.
- `exportAll_oneDestFails_stillPostsAllNotifications` — error doesn't suppress.
- `cancelMidRun_postsCancelledSummary` — assert content includes "Cancelled".

### G. `ExportSheetUIStateTests` (~3 tests, no XCUITest — just View state)
- `exportButton_disabled_whenProjectNameEmpty`.
- `runButton_disabled_whenAlreadyRunningForThatDest`.
- `closeFolderToolbarButton_disabled_whenAnyExportRunning` — verified via the same observable wiring.

Approx 60 tests total. Adds ~2-3 seconds to `xcodebuild test`.

XMP/ARW writer tests (`XMPSidecarTests`, etc.) already cover the sidecar mutation path; export only reads.

## Critical files to read before executing

- `/Users/frostman/workspace/personal/photo-x/PhotoX/Shoot/FavoriteShoots.swift` — singleton pattern + `move(_:before:)` to mirror.
- `/Users/frostman/workspace/personal/photo-x/PhotoX/Shoot/RecentShoots.swift` — UserDefaults injection pattern for tests.
- `/Users/frostman/workspace/personal/photo-x/PhotoX/StatusBarView.swift` (lines 82–110) — toggle-row + `starBinding` to clone for the destination rating filter.
- `/Users/frostman/workspace/personal/photo-x/PhotoX/ContentView.swift` (the favorites drag-reorder block + the `.toolbar { }` block) — to mirror drag UX and slot in the toolbar pill.
- `/Users/frostman/workspace/personal/photo-x/PhotoX/Model/ViewerState.swift` (`ratingCategory`/`isVisible`) — duplicate the 3-line match function into the export runner.
- `/Users/frostman/workspace/personal/photo-x/PhotoX/Metadata/XMPSidecarReader.swift` (line 10) — confirms XMP path is `<rawURL minus ext>.xmp`.
- `/Users/frostman/workspace/personal/photo-x/PhotoX/Model/PhotoPair.swift` — `rawURL`, `heifURL`, `stem`.

## Verification

End-to-end manual flow on a real shoot after the test suite is green:

1. **Persistence**: add 2–3 destinations with overlapping but distinct filters (e.g. "all stars" / "5★ only + remove orphans" / "rejected only"). Set project name "TestShoot". Quit + relaunch → all settings persist.
2. **Empty project name guard**: clear the project name → Export-all and per-dest Run buttons grey out; tooltip explains why.
3. **Per-destination Run**: click ▶ on a single destination → that one runs, others stay idle. Progress + ETA + currentFilename tick through. Notification posts on completion.
4. **Export all (Mode A)**: with the read-once flag OFF, click ▶ Export all → destinations run sequentially. Overall progress + ETA reflect aggregate. N-1 per-destination notifications + 1 final notification fire.
5. **Export all (Mode B)**: enable the read-once flag, re-run. Result is byte-identical to Mode A (spot-check by diffing). On a slow source (SD card) the run is visibly faster.
6. **Close-sheet-mid-run**: close the sheet during a run → toolbar pill shows live progress. Click pill → sheet reopens at exactly the same state.
7. **Close Folder blocked**: while running, Close Folder toolbar button is disabled with tooltip "Cannot close while an export is running."
8. **Quit guard**: while running, press ⌘Q → alert "Export in progress" with Stay (default) and red "Cancel exports and quit" button. Click Stay → app continues. Try again → click Cancel → exports cancelled, app quits.
9. **Cancel mid-run**: click Cancel all → state goes to `.cancelled` for active destinations; partial copies remain at destination; summary shows what was copied/skipped/cancelled.
10. **Idempotent re-run**: after a successful run, re-run with no changes → all files skipped (size + mtime within 1s). End summary: "copied 0, skipped N".
11. **Sidecar update**: change a rating in PhotoX, re-run → only the XMP for that pair copies (size differs); ARW/HIF stay skipped.
12. **XMP regression guard**: manually `touch -t` a destination XMP to 1 hour in the future, set policy to `alwaysOverwrite`, re-run → destination XMP unchanged; summary reflects skip.
13. **Remove-orphans**: enable on one destination, change a star rating so a previously-included pair falls out, re-run → confirmation dialog appears; on confirm, that pair's files are deleted from the destination; summary shows deleted count. Foreign files (a stray `.txt` you placed there) survive untouched.
14. **Errors continue the run**: chmod a single source ARW unreadable, re-run → that one file is recorded in `Summary.errors`; everything else still copies.

## What this constrains for Phase 5+

- The `ExportRunner` singleton lives the lifetime of the app and survives `closeShoot`. If the user closes the shoot mid-export, the running export keeps going (it captured the pairs + XMPs by value at start). The toolbar pill stays visible while running so the user can reopen and watch progress.
- The "remove orphans" feature is destructive. We confirm only at run-start; once running, no further confirmation. Future safety net could be a Trash-instead-of-delete option (`FileManager.trashItem(at:)`), trivially added later.
- Per-destination overwrite policies open the door to use-cases like "primary archive = never overwrite" + "working backup = always overwrite". No further work needed; just configure.
- No CI yet; the new test suites run locally via `xcodebuild test` alongside the existing 84.
- No telemetry / analytics on export performance. If big-shoot perf becomes a concern, instrument `ExportRunner` with `PerfTracker` later.
