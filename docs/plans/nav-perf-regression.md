# Navigation perf regression — surgical fixes + caches

## Context

Navigation in big folders is noticeably slower per arrow press than
it was at v0.182.0 (commit `e72c60222`). Audit pinned two
regressions plus two latent perf cliffs that are cheap to remove
while we're in the area.

### Suspect #1 (PRIME): `entryFiles(for:)` does 12 filesystem probes per nav

`PhotoX/Model/ViewerState.swift:1598-1612`, added in **1fd0364**
(JPG support, 2026-05-20).

```swift
private func entryFiles(for entry: PhotoEntry) -> EntryFiles {
    // ...
    return EntryFiles(
        arw: entry.rawURL.map { fm.fileExists(atPath: $0.path) } ?? false,  // 1 probe
        hif: fileExistsCaseInsensitiveAny(at: folder, stem: entry.stem,
                                          exts: ["HIF", "HEIF", "HEIC"]),    // 6 probes
        jpg: fileExistsCaseInsensitiveAny(at: folder, stem: entry.stem,
                                          exts: ["JPG", "JPEG"]),            // 4 probes
        xmp: fm.fileExists(atPath: entry.xmpURL.path)                         // 1 probe
    )
}
```

That's **12 `FileManager.fileExists` calls per arrow press**, up
from 3 at v0.182.0. On a CFExpress/SD card every `stat()` is
expensive relative to in-memory work, and the `hif`/`jpg` probes
are pure overhead — the answer is already encoded in
`entry.previewURL.pathExtension`. The pill switch in `filesBadge`
never displays "both formats" anyway (HIF wins per EntryFinder).

### Suspect #2 (PRIME): `burstSegment` walks the visible array per cell

`PhotoX/Model/ViewerState.swift:1084-1129`, changed in **d399a4f**
(close-shoot resets + burst bracket fix under filters, 2026-05-20).

Each visible cell walks the entire visible array left AND right
looking for any same-burst sibling. Worst case (unique burst ids
or all-nil ids on an un-indexed shoot): O(N) per cell × N rendered
cells = **O(N²) per filmstrip render**. With N=5000 entries and
~100 realised LazyHStack cells, that's hundreds of thousands of
dict lookups per arrow press, on top of the original constant-time
logic.

The "fix" this change enabled (`.solo` bracket for a lone visible
burst member) is genuine and we keep it — but it should cost
O(visible) **once per render**, not O(visible) **per cell**.

## Audit answers to two related questions

### `sortedEntries` — how often does it re-sort?

`PhotoX/Model/ViewerState.swift:162-182`. Costs depend on `sortMode`:

- `.name` (default; what most users use most of the time): returns
  `shoot.entries` directly — **O(1)**.
- `.scoreAscending` / `.scoreDescending`: full `sorted` closure —
  **O(N log N)** per access.

Per arrow press, `sortedEntries` is read ~5–10 times (entry getter,
displayedEntry getter, navigate, nextVisibleIndex, FilmstripView
body, sometimes navigateByBurst's inner walk). In `.name`: all
O(1), negligible. In score-sort: **5–10 × O(N log N) per press** —
on a 5000-entry shoot that's ~50–100 ms wasted per press. Latent
perf cliff: not the current regression (default sort is .name),
but worth caching since the fix is small.

### Collapse-bursts filter pass — how expensive?

`PhotoX/Filmstrip/FilmstripView.swift:38-48`, added in **f5f81bd**
(burst features, 2026-05-13). Filters `allVisible` with a
`Set<Int>` "seen ids" lookup — **O(visible)** per render. Gated
on `collapseBursts == true && useBrackets == true`, so users
who never toggle the feature pay nothing.

When the toggle is on, for a 5000-entry visible filmstrip that's
~5000 dict lookups + ~few hundred Set inserts per render. Cheap
per op (~10 ns each in Swift). Total: well under 1 ms even at
5000 entries. **Not a regression suspect**, no fix needed.

(The pre-existing `allVisible` computation that this pass filters
is also O(N over shoot) per render, but that pre-dates v0.182.0
and isn't a regression. Worth a closer look later if perf is
still bad after the prime-suspect fixes.)

## Approach

### Fix 1: `entryFiles` becomes pure-Swift (zero disk reads per nav)

Two parts:

(a) Derive `arw` / `hif` / `jpg` from the in-memory `PhotoEntry`
struct — no probes. The slots are stable for the lifetime of the
entry within a shoot (memory: cards are read-only for PhotoX; on
writable disks mid-session add/remove doesn't survive without a
re-scan):

```swift
let ext = entry.previewURL.pathExtension.lowercased()
let arwSlot = (entry.rawURL != nil)
let hifSlot = ["hif", "heif", "heic"].contains(ext)
let jpgSlot = ["jpg", "jpeg"].contains(ext)
```

(b) Record XMP-presence in a per-shoot `Set<String>`, populated
by the XMP indexer pipeline (which already reads every XMP). Per
navigation, `entryFiles.xmp` becomes an O(1) Set lookup — no
disk probe at all. Cleaner than a generic `entryFiles` cache:
PhotoEntry stays an immutable value type representing on-disk
identity, while the mutable "has-XMP" state lives on ViewerState
where session state belongs.

```swift
/// Stems whose `.xmp` sidecar exists on disk. Populated by the
/// XMP indexer pipeline as it scans each file; mutated when the
/// user writes a rating / label / reject (which creates the
/// sidecar if it didn't exist). Cleared on shoot switch.
private(set) var stemsWithXMPOnDisk: Set<String> = []

private func entryFiles(for entry: PhotoEntry) -> EntryFiles {
    let ext = entry.previewURL.pathExtension.lowercased()
    return EntryFiles(
        arw: entry.rawURL != nil,
        hif: ["hif", "heif", "heic"].contains(ext),
        jpg: ["jpg", "jpeg"].contains(ext),
        xmp: stemsWithXMPOnDisk.contains(entry.stem)
    )
}
```

Wiring the Set:

- **XMP indexer** (the existing pipeline at lines ~758-766):
  currently calls `XMPSidecarReader.read(for:)` for every entry;
  that helper returns a sentinel `.empty` for both missing files
  AND present-but-blank files. Replace its signature to return
  `XMPSidecar?` (nil = file missing), so the indexer can
  `stemsWithXMPOnDisk.insert(stem)` only when the file actually
  existed. `flushXMPSlice` keeps storing parsed sidecars into
  `entryXMPs[stem]` — that part doesn't change.
- **Rating mutations** (`setRating`, `setLabel`, `toggleReject`,
  `setRating(_:for:)`): after the XMPSidecarWriter call succeeds
  (or optimistically, alongside the `entryXMPs[stem] = updated`
  write), insert the stem into the Set. Writing a rating creates
  the sidecar if it didn't exist; insertion is idempotent.
- **Rollback paths** in those same mutators: if the XMP write
  fails AND we previously knew the file didn't exist, remove the
  stem from the Set. Cheap.
- **Shoot switch**: `resetForShootSwitch()` already wipes
  `entryXMPs` and the other per-shoot caches; add
  `stemsWithXMPOnDisk.removeAll()` next to them.

`XMPSidecarReader.read` is the only file that needs a signature
change. Two call sites: the indexer pipeline (we already plan to
adapt) and one read in `applyCurrentEntry` (line 936) that
currently uses the `??` fallback — that path can stay as-is by
defaulting `nil` to `.empty` at the call site (`reader.read(for:) ?? .empty`).

Net effect: every per-navigation disk read for entryFiles is
gone. **12 disk reads → 0**.

Delete the now-unused `fileExistsCaseInsensitiveAny` helper.

### Fix 2: `burstSegment` precompute first/last visible indices in FilmstripView

Keep the static helper for tests, but stop calling it from the
hot path. In `FilmstripView.body`, right after computing `visible`
/ `burstIDs` / `burstSizes`:

```swift
// Precompute first/last visible index per burst id — O(visible)
// once per render. Per-cell bracket lookup is then O(1).
var firstByBurst: [Int: Int] = [:]
var lastByBurst: [Int: Int] = [:]
if useBrackets {
    for (vIdx, entry) in visible.enumerated() {
        guard let id = burstIDs[entry.stem],
              (burstSizes[id] ?? 0) >= 2 else { continue }
        if firstByBurst[id] == nil { firstByBurst[id] = vIdx }
        lastByBurst[id] = vIdx
    }
}
```

Per-cell `segment` computation drops to dict lookups + index
compares:

```swift
let segment: ViewerState.BurstSegment = {
    guard useBrackets,
          let myID = burstIDs[entry.stem],
          let first = firstByBurst[myID],
          let last  = lastByBurst[myID] else { return .none }
    if first == last { return .solo }
    switch vIdx {
    case first: return .start
    case last:  return .end
    default:    return .middle
    }
}()
```

Whole filmstrip render goes from O(visible²) back to O(visible) —
the same Big-O as v0.182.0, with the bonus of the filter-resilient
`.solo` case retained.

`ViewerState.burstSegment(at:in:ids:sizes:)` stays unchanged so
`BurstSegmentTests` keeps passing without edits. FilmstripView
just doesn't call it any more.

### Fix 3: `sortedEntries` cache (latent score-sort cliff)

Cheap to add while we're in the area. Cache the computed
`[PhotoEntry]` array; invalidate on the three things that can
change ordering: shoot, sortMode, entryXMPs.

```swift
private var sortedEntriesCache: [PhotoEntry]?

var sortedEntries: [PhotoEntry] {
    if let cached = sortedEntriesCache { return cached }
    guard let shoot else { return [] }
    let computed: [PhotoEntry]
    switch sortMode {
    case .name: computed = shoot.entries
    case .scoreAscending:  computed = shoot.entries.sorted { /* …existing… */ }
    case .scoreDescending: computed = shoot.entries.sorted { /* …existing… */ }
    }
    sortedEntriesCache = computed
    return computed
}

private func invalidateSortedEntriesCache() {
    sortedEntriesCache = nil
}
```

Invalidation hooks:

- `resetForShootSwitch()`: `sortedEntriesCache = nil`.
- `setSortMode(_:)`: after writing `sortMode`,
  `invalidateSortedEntriesCache()`.
- The rating-mutation paths (`setRating`, `setLabel`,
  `toggleReject`, `setRating(_:for:)`): after the XMP write,
  `invalidateSortedEntriesCache()` (only matters when current
  sortMode != .name; safe to call always).

`.name` mode benefit: still O(1) but now via a cached reference
instead of repeated `shoot.entries` property accesses (negligible
but tidy). Score-sort modes: O(N log N) once after each rating
change, O(1) for every other access.

## Critical files to modify

| File | What changes |
|---|---|
| `PhotoX/Model/ViewerState.swift` | (a) Rewrite `entryFiles(for:)` to derive arw/hif/jpg from the struct + read xmp from new `stemsWithXMPOnDisk: Set<String>`. Delete `fileExistsCaseInsensitiveAny`. (b) Add `sortedEntriesCache` + invalidate hooks in `resetForShootSwitch`, `setSortMode`, `setRating`, `setLabel`, `toggleReject`, `setRating(_:for:)`. (c) XMP indexer pipeline inserts into `stemsWithXMPOnDisk` for files it found on disk. Rating mutators insert too. `resetForShootSwitch` clears. |
| `PhotoX/Metadata/XMPSidecarReader.swift` | Change `read(for:)` return type from `XMPSidecar` to `XMPSidecar?` — nil means "no file on disk" (was returning `.empty` for that case, which was indistinguishable from a present-but-blank XMP). |
| `PhotoX/Filmstrip/FilmstripView.swift` | Add the `firstByBurst` / `lastByBurst` precompute pass before the `ForEach`; compute `segment` inline per cell from those maps |

Two files. Existing tests (`BurstSegmentTests`, `ViewerStateFilterTests`,
`EntryFinderTests`, `RecentShootsTests`, `PendingReopenStoreTests`,
`XMPSidecarTests`, `MTLTextureCacheTests`, `ExportCopyLoopTests`,
`ExportNotificationsTests`, `ExportRunnerStateTests`,
`ExportSharedReadTests`, `IndexingStatusTests`, `PreviewBytesCacheTests`)
all stay green — no behavioural changes.

## Verification

1. `just build` → `just test` — both green; unchanged behaviour
   exercised by the existing 50+ tests.
2. `just e2e` — full suite green.
3. `just dev` (with user confirmation per memory) — open the user's
   real big shoot, hold the right arrow for 5 seconds. Comparison
   points:
   - Before: noticeable per-press latency.
   - After: should match v0.182.0's feel. The texture cache and
     prefetch already make nav near-instant when per-press costs
     are bounded by the texture lookup alone.
4. Spot-check the pill badge against an `ARW+JPG` entry (DSC00060
   in sample/): should still read `ARW+JPG`. Confirms the
   extension-derived slots work.
5. Spot-check a filtered burst (rate some members, hide them via
   the status-bar toggles): bracket should still show `.solo` /
   `.start` / `.end` correctly across the gaps. Confirms the
   precompute matches the previous walk's semantics.
6. Rate an entry → navigate back to it → confirm the rating
   badge appears and the stem-pill files badge includes XMP.
   Confirms the cache stays in sync with on-disk XMP writes.
7. Switch sort to "Score (high → low)" and navigate around →
   filmstrip should reorder correctly per rating; rating an
   entry should update the order on the next access (cache
   invalidates). Confirms the sortedEntries cache invalidation
   hooks fire.

## Out of scope

- Pre-warming `entryFilesCache` from the indexer's basic-EXIF
  batches — would amortise even the XMP first-probe away from the
  per-nav path. Useful if measurement shows residual nav lag
  after these fixes; skip for now.
- The pre-existing `allVisible` computation in FilmstripView
  (O(N over shoot) per render) — pre-dates v0.182.0, not a
  regression. Worth caching later if measurement points there.
