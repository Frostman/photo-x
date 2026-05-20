# Burst features: stem-pill badge, ⌘arrow nav, collapse toggle

## Context

PhotoX already detects bursts (consecutive Sony `SequenceNumber`
frames) and draws a bracket overlay across them in the filmstrip,
but the data does no other work for the user. Three additions turn
that latent grouping into real culling leverage:

1. **Stem-pill burst badge** — when the displayed pair is in a burst,
   add a small `X / Y in burst` chunk to the canvas stem pill so the
   user always knows where they are inside a burst without scanning
   the filmstrip.
2. **⌘← / ⌘→ "step by burst" navigation** — treat each burst (size
   ≥ 1; singletons count as a one-frame burst) as one step. ⌘→ from
   anywhere jumps to the first frame of the next burst. Singletons
   are not skipped. Sits alongside the existing ⌥arrow (skip 10) and
   bare arrow (skip 1) shortcuts.
3. **Collapse-bursts filmstrip toggle** — a button in the status bar
   that hides all-but-the-first frame of each burst in the
   filmstrip. The burst the user is currently inside auto-expands,
   the others stay collapsed. Navigation (arrows + ⌘arrow) still
   walks every frame — the collapse is purely a filmstrip-display
   thing. Persisted via `AppDefaults`.

## Approach

### 1. Stem-pill burst badge

Add one helper on `ViewerState` and one `Text` chunk in the stem pill.

`PhotoX/Model/ViewerState.swift` — new method near `burstSegment`
(after line 1081):

```swift
/// `(positionWithinBurst, burstSize)` for a stem that's part of a
/// burst (size ≥ 2). Returns nil for singletons / unknown stems.
/// Position is 1-based; bursts are contiguous in name-order so we
/// walk `shoot.pairs` once to find the burst's start index.
func burstPosition(for stem: String) -> (index: Int, total: Int)? {
    guard let id = burstIDByStem[stem],
          let size = burstSizesByID[id], size >= 2,
          let shoot,
          let idx = shoot.pairs.firstIndex(where: { $0.stem == stem })
    else { return nil }
    var start = idx
    while start > 0,
          burstIDByStem[shoot.pairs[start - 1].stem] == id {
        start -= 1
    }
    return (idx - start + 1, size)
}
```

`PhotoX/ContentView.swift` — extend the stem pill (lines 841–865) by
inserting one `Text` after `filesBadge` (before the closing HStack):

```swift
if let b = state.burstPosition(for: pair.stem) {
    Text("\(b.index)/\(b.total) burst")
        .foregroundStyle(.white.opacity(0.45))
        .accessibilityIdentifier("canvas.stemPill.burst")
}
```

Reuses the existing pill background + font — no styling fork.

### 2. ⌘← / ⌘→ burst-step navigation

Add one method on `ViewerState` that walks the visible array until
the burst id changes, then call it from the existing arrow handlers
(no new `.onKeyPress` registration — modifier branching, same as
how `.option` is handled today).

`PhotoX/Model/ViewerState.swift` — new method near `navigate(by:)`
(after line 1154):

```swift
/// Move to the first visible frame of the next/previous burst.
/// `direction` is +1 (next) or −1 (previous). Singletons count as
/// 1-frame bursts. When the sort isn't name-order, `burstIDByStem`
/// still has values but the groups aren't contiguous in the
/// visible array, so we fall back to single-step.
func navigateByBurst(direction: Int) {
    guard sortMode == .name,
          let startStem = sortedPairs[safe: currentIndex]?.stem else {
        navigate(by: direction)
        return
    }
    let startID = burstIDByStem[startStem]
    var idx = currentIndex
    while true {
        let next = nextVisibleIndex(from: idx, direction: direction)
        if next == idx { break }  // hit end
        let stem = sortedPairs[next].stem
        if burstIDByStem[stem] != startID {
            navigate(to: next)
            return
        }
        idx = next
    }
    // We were already in the last/first burst — sit at the boundary.
    navigate(to: idx)
}
```

(Uses the existing `nextVisibleIndex(from:direction:)` from line 1134.)
Add a `subscript(safe:)` extension on `Array` if one doesn't already
exist — one-liner, scoped to this file.

`PhotoX/ContentView.swift` — extend the existing arrow handlers
(lines 142–153) to branch on `.command` before the existing
`.option` check:

```swift
.onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in
    PerfTracker.begin("← key")
    if press.modifiers.contains(.command) {
        state.navigateByBurst(direction: -1)
    } else {
        let step = press.modifiers.contains(.option) ? 10 : 1
        state.navigate(by: -step)
    }
    return .handled
}
// mirror for .rightArrow
```

`PhotoX/HelpOverlay.swift` — add one line to the Navigation
section (line 36 area):

```swift
.init(keys: "⌘ ← / →", label: "Jump to previous / next burst"),
```

### 3. Collapse-bursts filmstrip toggle

Persisted Bool, status-bar button, filmstrip render update with an
auto-expand rule.

**Settings key** in `PhotoX/Settings/SettingsView.swift` (around
lines 12–30, matching the existing patterns):

```swift
static let collapseBursts = "settings.collapseBursts"
// In Defaults:
static let collapseBursts = false
```

`ViewerState` reads it via `@AppStorage` on its own (or via a passed
binding to the FilmstripView — the latter avoids coupling the model
to a settings key). The filmstrip already accesses `state` directly,
so a `@AppStorage` declared in `FilmstripView` itself is cleanest.

**Filmstrip rendering** in
`PhotoX/Filmstrip/FilmstripView.swift` — extend the
`enumeratedVisible` step (line 17–18 area) with a collapse pass:

```swift
@AppStorage(SettingsKey.collapseBursts, store: AppDefaults.shared)
private var collapseBursts = SettingsKey.Defaults.collapseBursts

// inside body, after enumeratedVisible is computed:
let currentBurstID = state.displayedPair
    .flatMap { state.burstIDByStem[$0.stem] }
let displayed: [(offset: Int, element: PhotoPair)] = {
    guard collapseBursts, state.sortMode == .name else {
        return enumeratedVisible
    }
    var seen: Set<Int> = []
    return enumeratedVisible.filter { _, pair in
        guard let id = state.burstIDByStem[pair.stem],
              let size = state.burstSizesByID[id], size >= 2
        else { return true }                 // singleton
        if id == currentBurstID { return true }  // current burst expanded
        return seen.insert(id).inserted          // first in this burst
    }
}()
```

Then use `displayed` everywhere `enumeratedVisible` was used. The
representative is the FIRST visible frame of the burst — predictable
and stable; no rating-driven recomputation.

**`Nx` badge** on collapsed-representative thumbs — extend
`FilmstripThumbnailView` with one new optional parameter
`collapsedBurstSize: Int?` (nil → no badge). Render in the top-left
of the thumb using the same style as the existing star/reject badges
(small black-translucent pill with `.caption2.bold`). FilmstripView
passes the size whenever a thumb is the representative AND its burst
isn't auto-expanded.

**Status-bar toggle** in `PhotoX/StatusBarView.swift` — add a new
button between `sortMenu` and the `Divider` (line ~22). Follow the
existing `indexingChip` pattern (`Button { … } label: { Image(...) }`
+ `.buttonStyle(.plain)` + `.help(...)`):

```swift
Button {
    collapseBursts.toggle()
} label: {
    Image(systemName: collapseBursts
        ? "rectangle.stack.fill"
        : "rectangle.stack")
        .foregroundStyle(collapseBursts ? .accentColor : .secondary)
}
.buttonStyle(.plain)
.help("Collapse bursts in filmstrip (\(collapseBursts ? "on" : "off"))")
.accessibilityIdentifier("statusbar.collapseBursts")
```

With the matching `@AppStorage` declared at the top of StatusBarView.

## Critical files to modify

- `PhotoX/Model/ViewerState.swift` — add `burstPosition(for:)` near
  line 1081 and `navigateByBurst(direction:)` near line 1154.
  Optionally add `Array.subscript(safe:)` helper.
- `PhotoX/ContentView.swift` — add burst-badge `Text` in the stem
  pill (~line 856) and ⌘ branch in both arrow handlers (~lines
  142–153).
- `PhotoX/Filmstrip/FilmstripView.swift` — `@AppStorage` for
  `collapseBursts`, the collapse filter pass, pass `collapsedBurstSize`
  through to `FilmstripThumbnailView`. Same file's
  `FilmstripThumbnailView` (lines 118–169) — add the `Nx` corner
  badge.
- `PhotoX/StatusBarView.swift` — add the toggle button between
  `sortMenu` and `Divider`.
- `PhotoX/Settings/SettingsView.swift` — add
  `SettingsKey.collapseBursts` + `Defaults.collapseBursts`.
- `PhotoX/HelpOverlay.swift` — add the ⌘arrow row to the Navigation
  section.

## Functions / data to reuse

- `state.burstIDByStem`, `state.burstSizesByID`,
  `state.sortMode` (= `.name` gate), `state.sortedPairs`,
  `state.isVisible(_:)`, `state.displayedPair` —
  already populated; no recomputation needed.
- `nextVisibleIndex(from:direction:)` (ViewerState.swift:1134) — the
  ⌘arrow walker reuses this verbatim.
- `SettingsKey` + `AppDefaults.shared` + `@AppStorage` —
  established pattern, used by every other persisted toggle.
- `XCUITest accessibility identifiers` — `canvas.stemPill.burst` and
  `statusbar.collapseBursts` follow the existing naming convention
  so future E2E tests can hook them.

## Verification

1. `just build` clean.
2. `just dev` — manual smoke:
   - Navigate to a known burst (the sample/ shoot has several).
   - Confirm the stem pill shows `3/9 burst` and the count is right
     for various burst sizes; confirm it disappears on singletons.
   - Press ⌘→ — focus should land on the FIRST frame of the next
     burst. ⌘← mirrors. Bare → still steps by 1.
   - Click the status-bar collapse toggle; confirm the filmstrip
     collapses each burst to its first frame with a `Nx` badge, and
     the burst the user is on stays expanded. Step into another
     burst with arrows — that one expands, the previous one
     collapses. Toggle off → back to full filmstrip.
   - Quit + relaunch — collapse toggle state persists.
3. `just test` — unit suite still green (no model changes that
   touch existing test surface).
4. `just e2e` — full XCUITest suite still green; the new
   accessibility identifiers are additive.

## Out of scope / follow-ups

- Auto-rate burst siblings (Shift+rating). Natural sequel.
- Compare-burst-members view (the strip-above-filmstrip mockup).
- A keyboard shortcut for the collapse toggle (e.g. `G`) — easy to
  add later if it becomes a frequent action.
- Highest-rated-as-representative for collapsed bursts. Today's
  "first frame" rule is predictable; "best-rated" would need
  observer wiring whenever ratings change. Revisit if first-frame
  feels wrong in practice.
