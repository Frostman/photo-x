# Burst-nav bug + nav/UX features + export polish + log gating

## Context

A grab-bag of items off the user's queue, all small-to-medium:

1. **Bug** — ⌘← / ⌘→ skips through multiple singleton entries when it
   shouldn't. Likely root cause: entries without a Sony SequenceNumber
   (JPG-only files, or entries before the advanced-EXIF pipeline has
   indexed them) get `burstIDByStem[stem] == nil`, and the current
   `navigateByBurst` boundary check `burstIDByStem[next.stem] != startID`
   evaluates `nil != nil` → false, so the walker never stops.
2. **Feat** — when "collapse bursts" is on, ⌥← / ⌥→ should jump by 10
   **entries** (where one burst = one entry), not 10 frames.
3. **Chore** — wrap per-navigation / per-input / per-image logs in
   `#if DEBUG` (PerfTracker calls; the audit found 13 unwrapped sites).
   Add a `.warning` log when `ThumbnailLoader` falls back to ImageIO
   because the embedded-thumb fast path didn't fire.
4. **Chore** — confirm export pipeline treats JPG identically to HIF
   end-to-end (already verified during exploration — just spell out the
   findings in the plan and add a couple of regression-safety lines to
   `EntryFinderTests`).
5. **Feat** — destination path in `ExportDestinationRow` becomes
   click-to-copy (matches the stem-pill copy convention).
6. **Feat** — `[` / `]` shortcuts: jump to previous / next unrated entry.
7. **Feat** — `j` shortcut: open a small jump-to dialog. Lets the user
   jump by 1-based index OR by entry stem with auto-completion. If all
   stem candidates share a common prefix (e.g. all start with `DSC0`),
   pre-fill it.
8. **Chore** — refuse to export into the source shoot folder.
9. **Feat** — `g` shortcut, only inside a burst: rejects the **other**
   burst members. New `SettingsKey.gRejectScope` = "unrated only"
   (default) | "all other".
10. **Feat** — persist last-viewed entry stem per favorite / recent shoot;
    when reopening, focus that entry (silently fall back to the first
    entry if the saved stem no longer exists).

## Approach

### 1. Fix `navigateByBurst` for nil burst IDs

`PhotoX/Model/ViewerState.swift` (~line 1185):

Add a private helper that treats nil burst id as "this entry is its own
burst" instead of "matches every other nil":

```swift
/// Two entries belong to the same burst only when both have a
/// known burst id AND those ids are equal. Anything with nil id
/// (no SequenceNumber yet, JPG-only entries, etc.) is its own
/// "burst-of-one" — so ⌘arrow walks one step at a time across
/// rows of singletons instead of running off the end.
private func sameBurst(_ a: String, _ b: String) -> Bool {
    guard let ia = burstIDByStem[a], let ib = burstIDByStem[b]
    else { return false }
    return ia == ib
}
```

Then replace every `burstIDByStem[X.stem] != startID` test inside
`navigateByBurst` with `!sameBurst(startStem, sortedEntries[next].stem)`
(and the backward-walk equivalent against `prevStem`). Same scope; no
new behavior for genuine bursts; correct behavior for nil-id rows.

### 2. ⌥arrow jumps by entries when collapse is on

Add `navigate(byEntries:)` next to `navigate(by:)` in `ViewerState.swift`:

```swift
/// Walk `steps` entry boundaries (sign = direction). A multi-frame
/// burst counts as ONE entry — used by ⌥arrow when collapse-bursts
/// is on. Reuses `nextVisibleIndex` for the per-frame walk; only
/// the "did we cross into a different entry" check differs.
func navigate(byEntries steps: Int) {
    guard steps != 0 else { return }
    let direction = steps > 0 ? 1 : -1
    var idx = currentIndex
    var crossedBoundaries = 0
    let limit = abs(steps)
    while crossedBoundaries < limit,
          let next = nextVisibleIndex(from: idx, direction: direction) {
        if !sameBurst(sortedEntries[idx].stem, sortedEntries[next].stem) {
            crossedBoundaries += 1
        }
        idx = next
        // After crossing into a forward burst, fast-forward to its
        // *first* frame is automatic — `idx` lands on the first new-id
        // frame the loop sees. (Backward direction lands on the LAST
        // frame of the prev burst; users said landing on first/last
        // matches the ⌘← convention from the burst-features PR.)
    }
    // For backward direction, mirror ⌘←'s "land on first frame of the
    // target entry" by walking back inside the entry once we've used
    // up our budget.
    if direction < 0,
       let firstOfTarget = walkBackToBurstStart(from: idx) {
        idx = firstOfTarget
    }
    navigate(to: idx)
}

private func walkBackToBurstStart(from start: Int) -> Int? {
    guard let id = burstIDByStem[sortedEntries[start].stem] else { return start }
    var i = start
    while let prev = nextVisibleIndex(from: i, direction: -1),
          burstIDByStem[sortedEntries[prev].stem] == id {
        i = prev
    }
    return i
}
```

Expose `collapseBursts` on `ViewerState` so the arrow handlers can
branch without each one importing `@AppStorage`:

```swift
// In ViewerState.swift
var collapseBurstsActive: Bool {
    AppDefaults.shared.bool(forKey: SettingsKey.collapseBursts)
}
```

`PhotoX/ContentView.swift` arrow handlers (lines ~142-160): branch
`navigate(by:)` vs `navigate(byEntries:)` when `.option` modifier is
held AND `state.collapseBurstsActive` is true.

### 3. Gate per-nav logs + add fast-path miss log + memory

`PhotoX/Util/PerfTracker.swift`: wrap the call sites at the SOURCE not
the call site (less churn). Two options:

- **(a)** Add an internal `#if DEBUG` around the Logger emit in
  `begin(_:)` and `mark(_:)`. Public API unchanged; release builds
  pay only the function-call overhead.
- **(b)** Wrap every individual call site in `#if DEBUG`.

Go with **(a)** — one place to maintain, no churn at 13 call sites.

`PhotoX/Filmstrip/ThumbnailLoader.swift` (~line 65): add when entering
the ImageIO fallback path:

```swift
Log.app.warning("thumbnail fast-path missed for \(url.lastPathComponent, privacy: .public) — falling back to ImageIO full decode")
```

This is a real signal (slow path used) so it stays unconditional —
qualifies under the "errors/warnings" exception in the new memory.

**Memory** to save:

> Per-navigation / per-input / per-image logs must be DEBUG-only.
> Release builds stay quiet — `.error` for real failures, `.warning`
> for "we fell back to a slow path" / configuration issues; `.notice`
> for one-off lifecycle events only. Reason: noisy Logger emits in
> Console.app for users who poke around, and a non-trivial perf cost
> at the navigation hot path. How to apply: any new log on the
> arrow / key / decode / nav / indexer-batch / render-frame path goes
> inside `#if DEBUG`.

Memory file: `feedback_release_logs_only_errors_and_lifecycle.md`,
index entry added to `MEMORY.md`.

### 4. Confirm + lock-in JPG export parity

The exploration confirmed end-to-end parity:
- `ExportPlanner.plan(…)` iterates `entry.previewURL` regardless of
  format.
- `ExportRunner.removeOrphansOffMain` already lists
  `["arw", "hif", "heif", "heic", "jpg", "jpeg", "xmp"]`.
- `OverwriteDecision.decide(…)` is purely size/mtime/sha — no
  HIF-specific assumption.

Add 2 quick regression cases to `PhotoXTests/EntryFinderTests.swift`
already exists; export tests are already covered by `ExportCopyLoopTests`.
We'll just add ONE new `ExportCopyLoopTests` case that constructs an
ARW+JPG entry and asserts the JPG ends up in the output folder when
`includeHIF == true`. No code changes in `Export/`.

### 5. Click-to-copy destination path

`PhotoX/Export/ExportDestinationRow.swift` (~line 36-40): wrap the
existing `Text(...abbreviatingWithTildeInPath)` in a `Button { … }
.buttonStyle(.plain)` that pushes the absolute path to
`NSPasteboard.general`. Add a brief copy flash (200 ms label flip
to "Copied path") — same convention as the canvas stem-pill
(`copiedFlash` in ContentView). Update `.help(...)` to "Click to copy
absolute path".

### 6. `[` / `]` → prev/next unrated

Brackets (no shift required on US layout) keep the right hand on the
filmstrip arrows without stretching to comma/period.

`ViewerState.swift`: add navigation helpers next to the existing ones.

```swift
func nextUnrated() {
    walkRated(direction: 1)
}
func previousUnrated() {
    walkRated(direction: -1)
}
private func walkRated(direction: Int) {
    var idx = currentIndex
    while let next = nextVisibleIndex(from: idx, direction: direction) {
        let stem = sortedEntries[next].stem
        let rating = entryXMPs[stem]?.rating
        if rating == nil || rating == 0 {
            navigate(to: next); return
        }
        idx = next
    }
    // No unrated in that direction — sit still.
}
```

`PhotoX/ContentView.swift` shortcut block: register
`.onKeyPress(KeyEquivalent("["))` → `state.previousUnrated()` and
`.onKeyPress(KeyEquivalent("]"))` → `state.nextUnrated()`. HelpOverlay
gets one line in the Navigation section.

### 7. `j` jump-to dialog

`@State private var showJumpSheet = false` in ContentView.
`.onKeyPress(KeyEquivalent("j"))` toggles it. Same conditional gate
as the other shortcuts (skip when export sheet up).

New view `PhotoX/JumpToView.swift`:

```swift
struct JumpToView: View {
    @Bindable var state: ViewerState
    let onDismiss: () -> Void
    @State private var query: String = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("Jump to").font(.headline)
            TextField("Index (1-N) or stem (e.g. DSC04207)", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onSubmit { jump() }
                .onAppear {
                    query = commonStemPrefix()
                    queryFocused = true
                }
            // Live completion list (up to 8 matches).
            ForEach(filteredStems.prefix(8), id: \.self) { stem in
                Button(stem) { query = stem; jump() }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { onDismiss() }
                Spacer()
                Button("Jump") { jump() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 360)
    }

    private var filteredStems: [String] {
        guard let entries = state.shoot?.entries, !query.isEmpty else {
            return state.shoot?.entries.map(\.stem) ?? []
        }
        return entries.map(\.stem).filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func commonStemPrefix() -> String {
        // Greatest common alphabetic prefix across all stems in the
        // shoot. "DSC04177", "DSC04178" → "DSC0".
        guard let stems = state.shoot?.entries.map(\.stem), !stems.isEmpty else { return "" }
        var prefix = stems[0]
        for s in stems.dropFirst() {
            while !s.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    private func jump() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let idx = Int(q),
           let total = state.shoot?.count,
           idx >= 1, idx <= total {
            state.navigate(to: idx - 1)   // 1-based → 0-based
        } else if let target = state.shoot?.entries.first(where: { $0.stem == q }) {
            state.navigate(to: state.shoot!.index(of: target) ?? 0)
        } else if let firstMatch = filteredStems.first,
                  let target = state.shoot?.entries.first(where: { $0.stem == firstMatch }) {
            state.navigate(to: state.shoot!.index(of: target) ?? 0)
        }
        onDismiss()
    }
}
```

Presented as a SwiftUI `.sheet(isPresented: $showJumpSheet) { JumpToView(…) }`
in ContentView's body. `showExportSheet`-style gating: the existing
`.conditional(!showExportSheet)` chain on `.onKeyPress` extends to
also exclude the jump sheet so digits inside the dialog don't toggle
ratings.

### 8. Can't export into source

`PhotoX/Export/ExportSheet.swift` — when the user picks a destination
folder, reject if it's the same as `state.shoot?.folderURL.path`
(case-insensitive on default macOS APFS). Show an NSAlert: "PhotoX
won't export back into the source shoot folder. Pick another folder."
The cleanest hook is the existing `pickDestinationFolder()` /
`settings.add(path:)` site — refuse pre-add. Also defensively guard
in `ExportPlanner.plan(…)`: return an empty Plan with a warning when
`outputFolder.standardizedFileURL == shootURL.standardizedFileURL`
so the runner can surface an error if somehow it slips through.

### 9. `g` reject-burst-siblings + setting

`PhotoX/Settings/SettingsView.swift` — new key:

```swift
static let gRejectScope = "settings.gRejectScope"
// Defaults: "unrated"     ("unrated" | "all")
static let gRejectScope = "unrated"
```

`SettingsView` body: a Picker with two options:
- "Only unrated siblings" (default)
- "All other siblings"

`ViewerState.swift` — new helper:

```swift
/// Reject siblings of the displayed entry's burst. `scope` is
/// "unrated" (skip starred / labeled siblings) or "all" (reject
/// every other member). No-op outside a burst.
func rejectBurstSiblings(scope: GRejectScope) {
    guard let stem = displayedEntry?.stem,
          let id   = burstIDByStem[stem],
          let size = burstSizesByID[id], size >= 2 else { return }
    let siblings = sortedEntries.filter {
        $0.stem != stem && burstIDByStem[$0.stem] == id
    }
    for sib in siblings {
        let xmp = entryXMPs[sib.stem]
        let isUnrated = (xmp?.rating ?? 0) == 0 && xmp?.label == nil && !(xmp?.isReject ?? false)
        switch scope {
        case .unrated:  if isUnrated { setRating(-1, for: sib, source: .keyboard) }
        case .all:      setRating(-1, for: sib, source: .keyboard)
        }
    }
}
```

`setRating(_:for:source:)` doesn't currently take an entry parameter
(it operates on `displayedEntry`). We extend the rating path with a
small variant that mutates an arbitrary entry's XMP — same write
helper, just doesn't move the canvas. This is the smallest necessary
addition; ratings UI / keyboard "3" etc. continue using the existing
displayed-entry path unchanged.

`PhotoX/ContentView.swift`: `.onKeyPress(KeyEquivalent("g"))` →
`state.rejectBurstSiblings(scope: gRejectScope)`. HelpOverlay row.

### 10. Persist last-viewed entry per shoot

`PhotoX/Loading/RecentShoots.swift` + `FavoriteShoots.swift`: structural
refactor from `[String]` to `[StoredShoot]`:

```swift
struct StoredShoot: Codable, Hashable, Sendable {
    let path: String
    var lastEntryStem: String?
    // future: lastViewedAt: Date?
}
```

Storage moves to JSON-encoded `Data` under a new key
`recentShoots.json` / `favoriteShoots.json`. On init, migrate from
the old `stringArray(forKey:)` key (one-time, then leave the legacy
key alone — its data stays intact even though we no longer read it,
so a downgrade-then-upgrade round trip recovers gracefully).

API additions on each store:

```swift
func setLastEntry(_ stem: String?, for path: String)
func lastEntry(for path: String) -> String?
```

`ViewerState.loadShoot(_:focus:)` (line 444) — add an optional
`focusStem: String? = nil` parameter and resolve in order:
1. explicit `focus: PhotoEntry?` (caller passes one)
2. `focusStem` → look up entry by stem
3. `shoot.entries.first`

Then update the two save points:
- `ViewerState.resetForShootSwitch()` (line ~538): just before the
  reset, capture `(currentShoot?.folderURL.path, displayedEntry?.stem)`
  and push to BOTH stores' `setLastEntry`.
- `PhotoXApp` SwiftUI scene `.onChange(of: scenePhase)` when
  `scenePhase == .background` — same capture.

Callers of `loadShoot` to update:
- `PhotoXApp.bootstrap()` — pass `focusStem: RecentShoots.shared.lastEntry(for: path)` or favorites equivalent (whichever store the path is in).
- The favorite / recent click handler in ContentView's sidebar.
- Drag-and-drop / Open-panel path: no saved stem, pass nil.

Silent fall-back: if `lastEntryStem` doesn't resolve to an entry
(stem deleted off card, re-rated set, etc.), use first entry, log
nothing. The store's stale stem can stay — next save overwrites it.

## Critical files to modify

| File | What changes |
|---|---|
| `PhotoX/Model/ViewerState.swift` | `sameBurst` helper, `navigateByBurst` uses it, `navigate(byEntries:)` + `walkBackToBurstStart` helper, `collapseBurstsActive`, `nextUnrated`/`previousUnrated`/`walkRated`, `rejectBurstSiblings`, `loadShoot` focusStem param, `resetForShootSwitch` save-point hook |
| `PhotoX/ContentView.swift` | arrow handlers branch on collapse for ⌥; new key handlers for `[` / `]` / `j` / `g`; `@State var showJumpSheet`; `.sheet` modifier; favorite/recent click handlers pass saved stem |
| **`PhotoX/JumpToView.swift`** (new) | the jump dialog |
| `PhotoX/HelpOverlay.swift` | new shortcut rows for `,` `.` `j` `g` |
| `PhotoX/Settings/SettingsView.swift` | `SettingsKey.gRejectScope` + `Defaults.gRejectScope`; Picker UI |
| `PhotoX/Util/PerfTracker.swift` | gate the Logger emits with `#if DEBUG` |
| `PhotoX/Filmstrip/ThumbnailLoader.swift` | `.warning` log on fast-path miss |
| `PhotoX/Export/ExportDestinationRow.swift` | wrap path Text in click-to-copy Button; brief copied-flash |
| `PhotoX/Export/ExportSheet.swift` | refuse source-as-destination via NSAlert in `pickDestinationFolder` |
| `PhotoX/Export/ExportPlanner.swift` | defensive guard for output == source returning empty plan |
| `PhotoX/Loading/RecentShoots.swift` | `[String]` → `[StoredShoot]` Codable JSON; legacy migration; `setLastEntry`/`lastEntry` |
| `PhotoX/Loading/FavoriteShoots.swift` | mirror RecentShoots refactor |
| `PhotoX/PhotoXApp.swift` | bootstrap reads saved stem; `scenePhase` background save hook |
| `PhotoXTests/ExportCopyLoopTests.swift` | new case: ARW+JPG entry → JPG ends up in output when includeHIF=true |
| `PhotoXTests/RecentShootsTests.swift` (or equivalent) | legacy migration test + setLastEntry round-trip |

## Reuse / leverage

- `sameBurst(_:_:)` — single source of truth for "same burst" so the
  bug fix and the new ⌥arrow logic stay consistent.
- `nextVisibleIndex(from:direction:)` — every nav helper above hooks
  through it; respects rating-filter toggles automatically.
- `XMPSidecarWriter.updateRating(_:for:)` — already takes a
  `PhotoEntry`, so the new arbitrary-entry rating path needs no
  XMP-writer changes.
- `copiedFlash` pattern in ContentView (stem-pill) — mirror it for the
  destination-path copy flash.
- `OverwriteDecision` is already format-agnostic; the new JPG export
  test is purely an integration assertion, no code change.
- `AppDefaults.shared` + `SettingsKey` — established pattern for the
  new `gRejectScope` toggle and the future stem persistence.

## Verification

1. `just build` clean.
2. `just test` — unit suite green. Two new cases pass (export JPG, recents
   migration).
3. `just dev` (wait for user prompt per the memory) — manual smoke:
   - **Bug**: navigate to a sequence of singletons (any folder without
     consecutive Sony bursts); ⌘→ advances one entry at a time.
   - **⌥arrow**: turn collapse-bursts on, ⌥→ in a shoot with bursts of
     varying sizes — should land 10 entries later, not deep inside one
     burst.
   - **Logs**: build release configuration (`xcodebuild -configuration
     Release` via a one-off), launch, navigate, watch Console.app for
     `dev.frostman.PhotoX` — only error/warning/lifecycle entries.
   - **Fast-path miss**: drop a non-camera JPG (web-edited, no IFD1) into
     a test folder, open it; Console should show one `.warning`
     `thumbnail fast-path missed for …`.
   - **Click destination path**: open Export sheet, click a destination
     path, verify clipboard has the absolute path and the row briefly
     shows "Copied".
   - **,/.**: rate a few frames; `,` and `.` skip starred ones.
   - **j**: press; dialog opens; common prefix pre-filled; type partial
     stem; suggestions narrow; Enter or click jumps.
   - **g**: navigate into a burst; press `g`; only unrated siblings get
     ✗. Flip setting to "all"; press `g`; every other sibling gets ✗.
   - **Source export refusal**: pick the current shoot's folder as a
     destination; NSAlert appears; folder is not added.
   - **Last entry restore**: navigate to pair 42 in a favorited shoot;
     quit (⌘Q); relaunch; the favorite reopens on pair 42.
4. `just e2e` — full suite still green. The new identifiers / sheets are
   additive, no existing E2E should regress.
5. Production-prefs sanity — `dev.frostman.PhotoX.plist` sha unchanged
   pre/post a full E2E run (the test isolation we already shipped
   should hold; new RecentShoots / FavoriteShoots writes flow through
   `AppDefaults.shared`).

## Out of scope / follow-ups

- Live-updating "last entry" on every nav (we save only on shoot
  switch + app background per the user's call; a crash mid-session
  loses the in-flight position — acceptable).
- A "reject everything below ★N" key. Natural sequel to `g` for
  whole-shoot grooming.
- The `j` dialog supporting fuzzy match (LCS) instead of plain
  substring. Substring is the right starting point.
- Migrating away from the legacy `recentShoots.paths` /
  `favoriteShoots.paths` UserDefaults keys (they stay readable but
  unused). Tidy-up in a later PR after we're confident the new format
  has shipped.
