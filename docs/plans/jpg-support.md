# JPG support as a HIF peer (+ honest renames: PhotoEntry / preview)

## Context

Today PhotoX only handles `ARW + HIF` pairs. The Sony A1 II reference
camera also writes `ARW + JPG` (in RAW+JPG capture mode), and the
user's working card already contains at least one orphan JPG today.
Other shooters also work in JPG-only folders. PhotoX should:

- Pair `ARW + JPG` the same way it pairs `ARW + HIF`.
- Show standalone `JPG` (no ARW) and standalone `HIF` (no ARW) as
  single-file entries — the entity is no longer always a "pair".
- When **both** `HIF` and `JPG` exist for the same stem, keep using
  `HIF` and ignore the `JPG` (per the user's request).
- Show the actual preview format in the canvas pill: `ARW+HIF`,
  `ARW+JPG`, `HIF`, `JPG`.
- The export toggle currently labelled `HIF` becomes `HIF/JPG` —
  one toggle covers either preview format (chosen by what the entry
  actually has on disk).

Since the "always a pair" invariant goes away, we rename for honesty
in the same PR — the code reads accurately going forward instead of
acquiring a "pair-that's-actually-one-file" mental tax:

- `PhotoPair` → `PhotoEntry` (struct + filename + every reference)
- `PairFiles` → `EntryFiles`, `PairFinder` → `EntryFinder`
- `ViewerState.pair` / `displayedPair` → `entry` / `displayedEntry`
- `pairXMPs` / `pairExif` / `pairSequenceNumber` → `entryXMPs` /
  `entryExif` / `entrySequenceNumber`
- `currentPairFiles` → `currentEntryFiles`
- `ImageVariant.heif` → `.preview` (the case still routes through
  `HEIFDecoder`, which is ImageIO-based and decodes JPG too)
- Local var conventions: `pair` → `entry` at touched sites; leave
  untouched files alone to keep the diff readable.

Out of scope: `ARW`-only entries (no preview). Not requested.

## Approach

The work splits into a small model change + a tail of follow-on
edits in scanner / canvas / export / UI / tests.

### 1. Model (the core change)

**Rename** `PhotoX/Model/PhotoPair.swift` → `PhotoX/Model/PhotoEntry.swift`:

```swift
struct PhotoEntry: Identifiable, Hashable, Sendable {
    /// Sony RAW; nil for standalone HIF / JPG entries.
    let rawURL: URL?
    /// Always present. HIF preferred; JPG when no HIF exists.
    let previewURL: URL
    let stem: String
    var id: String { stem }

    /// Sidecar lives next to the RAW if we have one, otherwise next
    /// to the preview. Either way it's `<stem>.xmp` in the same folder.
    var xmpURL: URL {
        (rawURL ?? previewURL).deletingPathExtension()
            .appendingPathExtension("xmp")
    }

    /// `.jpg` / `.jpeg` (case-insensitive) — used by UI / status
    /// text to label the preview format honestly.
    var hasJPGPreview: Bool {
        let ext = previewURL.pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }
}
```

**Rename** `PhotoX/Loading/PairFinder.swift` → `EntryFinder.swift`,
rewrite to accept any of: `ARW+HIF`, `ARW+JPG`, `HIF`-only,
`JPG`-only; preference order `HIF > JPG`; drop `ARW`-only.

```swift
enum EntryFinder {
    private static let rawExtensions:  Set<String> = ["arw"]
    private static let heifExtensions: Set<String> = ["hif", "heif", "heic"]
    private static let jpgExtensions:  Set<String> = ["jpg", "jpeg"]

    static func entries(in urls: [URL]) -> [PhotoEntry] {
        var byStem: [String: (raw: URL?, heif: URL?, jpg: URL?)] = [:]
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            var slot = byStem[stem] ?? (nil, nil, nil)
            if      rawExtensions.contains(ext)  { slot.raw  = url }
            else if heifExtensions.contains(ext) { slot.heif = url }
            else if jpgExtensions.contains(ext)  { slot.jpg  = url }
            else { continue }
            byStem[stem] = slot
        }
        return byStem.compactMap { stem, slot in
            guard let preview = slot.heif ?? slot.jpg else {
                return nil   // ARW-only: out of scope
            }
            return PhotoEntry(rawURL: slot.raw, previewURL: preview, stem: stem)
        }
        .sorted { $0.stem < $1.stem }
    }
}
```

`Shoot.swift` holds `let pairs: [PhotoPair]` — rename that property
to `entries: [PhotoEntry]` and update every `shoot.pairs` reader
(grep). Memory references to `pairs.count` etc. get renamed too.

### 2. Canvas / decoder / variant

`ImageVariant`:

```swift
enum ImageVariant: String, CaseIterable, Identifiable, Hashable, Sendable {
    case preview          // was .heif — covers HIF, HEIF, HEIC, JPG, JPEG
    case raw
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .preview: return "Preview"
        case .raw:     return "RAW"
        }
    }
}
```

Every `.heif` pattern match becomes `.preview`. **Also rename**
`HEIFDecoder` → `PreviewDecoder` (it routes HEIF/HEIC/JPG through
the same ImageIO call; the name should match the variant). The
existing `HIFBytesCache` is the only thing keyed off "raw bytes of
the preview file" — it gets renamed to `PreviewBytesCache` so the
naming chain is consistent (`.preview` variant → `PreviewDecoder` →
`PreviewBytesCache`). `HEIFEmbeddedThumbnail` keeps its name — it
genuinely only parses HEIF's ISOBMFF box structure; JPGs route
through the ImageIO fallback in `ThumbnailLoader`.

Format-honest UI labels: anywhere we'd previously hardcode "HEIF"
in user-visible text, branch on `entry.hasJPGPreview`. Specifically
`canvas.statusText` reads `"JPEG • 31% • AF"` for JPG entries
(uppercase JPEG — matches the HEIF capitalisation convention even
though the file extension is `.jpg`).

`PhotoX/Decoders/DecodePipeline.swift` — when a `.raw` variant is
requested for an entry with `rawURL == nil`, fall back to `.preview`
(don't fail loudly).

`PhotoX/Model/ViewerState.swift` — call sites:

- `pairFiles(for:)` (~line 1418) → rename `entryFiles(for:)`;
  extend `EntryFiles` struct with `var jpg: Bool = false`. The
  `.jpg` slot reflects "is there a `<stem>.jpg` / `.jpeg` on disk",
  whether or not we're using it (so the badge can be honest).
- `maybeAutoSwap()` (~line 1371) — guard with `entry?.rawURL != nil`;
  no RAW means no swap to RAW.
- `toggleRequestedVariant()` (~line 1226) — guard the same way; Z
  becomes a no-op for preview-only entries.
- `applyCurrentPair()` (~line 1399) → rename `applyCurrentEntry()`;
  leave `displayedVariant`/`requestedVariant` as `.preview`.
- Rename `pair` and `displayedPair` (`@Observable` properties);
  rename `pairXMPs`, `pairExif`, `pairSequenceNumber`,
  `currentPairFiles`. SwiftUI `state.pair` reads in views become
  `state.entry`, etc. ContentView + Sidebar + Filmstrip all touch
  these — single grep + replace per name.

### 3. JPG thumbnail extraction (same fast path as HEIF)

Promote the JPG case in the basic-EXIF + thumbs pipeline from
"decode the full file via ImageIO" to a header-only fast path that
mirrors HEIF. Camera JPGs carry an embedded ~160×120 thumbnail in
EXIF IFD1 — we extract it the same way `HEIFEmbeddedThumbnail`
extracts the embedded JPEG item from an HEIF.

Add `PhotoX/Decoders/JPEGEmbeddedThumbnail.swift` (new):

```swift
enum JPEGEmbeddedThumbnail {
    struct Extracted: Equatable {
        let jpeg: Data            // tiny IFD1 thumb, ready to decode
        let exifOrientation: Int  // IFD0 Orientation tag
        let exifBytes: Data?      // TIFF bytes for TIFFEXIFParser
    }
    /// Read the first ~256 KB of the JPG, walk SOI/APPn/SOS
    /// markers, locate the APP1 "Exif\0\0" segment, then walk
    /// IFD0 (orientation, sidebar EXIF bytes) + IFD1 (embedded
    /// thumbnail byte range via tags 0x0201/0x0202).
    static func extract(from url: URL) throws -> Extracted?
}
```

JPG markers are far simpler than HEIF's ISOBMFF — expect ~100-150
lines including the IFD1 walk. Most Sony / Canon / Nikon camera
JPGs carry IFD1 unconditionally; web-edited JPGs may not, in which
case we return `nil` and `ThumbnailLoader` falls back to ImageIO's
reduced-resolution decode (still cheap for JPG via 1/8 DCT, just
not as cheap as a 5 ms tiny-thumb decode).

`PhotoX/Filmstrip/ThumbnailLoader.swift` — dispatch on extension:

```swift
let ext = url.pathExtension.lowercased()
let extracted: HEIFEmbeddedThumbnail.Extracted?
if ["hif", "heif", "heic"].contains(ext) {
    extracted = HEIFEmbeddedThumbnail.extract(from: url)
} else if ["jpg", "jpeg"].contains(ext) {
    extracted = JPEGEmbeddedThumbnail.extract(from: url).map {
        .init(jpeg: $0.jpeg,
              exifOrientation: $0.exifOrientation,
              exifBytes: $0.exifBytes)
    }
} else { extracted = nil }
// downstream decode + TIFFEXIFParser pipeline unchanged
```

Light type-aliasing keeps the rest of the loader on one shape; or
factor a tiny shared `EmbeddedThumb` struct.

Outcome: JPG entries get the SAME treatment as HIF in the basic-
EXIF + thumbs indexer pipeline — fast first-paint thumb, sidebar
EXIF in the same pass, no exiftool round-trip.

### 4. UI surfaces

`PhotoX/ContentView.swift` — `filesBadge` (~line 882). Switch over
`(arw, hif, jpg)`, with the rule "if HIF exists ignore JPG":

```swift
switch (files.arw, files.hif, files.jpg) {
case (true, true, _):     return "ARW+HIF"
case (true, false, true): return "ARW+JPG"
case (true, false, false): return "ARW"
case (false, true, _):    return "HIF"
case (false, false, true): return "JPG"
case (false, false, false): return ""
}
```

`canvas.statusText` (already wired) — the existing string today says
"HEIF • 31% • AF". For JPG pairs it should read "JPG …" so the user
can tell at a glance. Adjust `statusText(image:)` to derive the
format-label from `pair.hasJPGPreview` rather than the hardcoded
"HEIF" string.

`PhotoX/HelpOverlay.swift` — change `Z: Toggle HEIF ↔ RAW` to
`Z: Toggle preview ↔ RAW (HEIF or JPG)`; `⌘O: Open ARW + HIF pair` →
`⌘O: Open folder`.

`PhotoX/Settings/SettingsView.swift` — `Auto-swap HEIF → RAW…`
toggle label → `Auto-swap preview → RAW when zoomed past 100%`.

Error/help-text touch-ups in `ContentView.swift` and
`PhotoXApp.swift` (the 6 hits the agent found) — switch from
"ARW + HIF pairs" to "ARW + HIF/JPG pairs". Phrasing kept close so
they don't get longer than the existing pill width.

### 5. Export

`PhotoX/Export/ExportDestinationRow.swift` (~line 131) — toggle
label `"HIF"` → `"HIF/JPG"`. `.help("Copy .HIF files")` →
`"Copy .HIF or .JPG files (whichever the pair has)"`.

`PhotoX/Export/ExportSettings.swift` — keep the `includeHIF: Bool`
field name (renaming would break already-persisted user settings).
Update its doc comment to note it covers both formats.

`PhotoX/Export/ExportPlanner.swift` — wherever it currently copies
`pair.heifURL`, copy `pair.previewURL` (just the rename — same
toggle gates it).

`PhotoX/Export/ExportRunner.swift` (~line 869) — add `jpg`/`jpeg`
to `managedExtensions` so orphan-prune handles them.

### 6. File-extension whitelists + open panel

- `PhotoX/Shoot/FolderStats.swift` (~line 47-48, 77-78) — add JPG
  extensions to its sets so folder-summary chips count
  preview-having pairs correctly.
- `PhotoX/Loading/OpenPanelCoordinator.swift` (~line 18-19) — add
  JPG UTType to the allowed list; update the panel message string.

### 7. README + sample

`README.md` — file-requirements section (lines 132-146): describe
that a pair is `ARW + HIF`, `ARW + JPG`, standalone `HIF`, or
standalone `JPG`; HIF preferred when both preview formats exist.

The sample/ folder already contains a `DSC00060.JPG` (orphan today)
+ a `DSC00060.ARW`. With the new pairing logic this becomes an
`ARW+JPG` pair organically — no new fixture needed.

### 8. Tests

`PhotoXUITests/PhotoXUITestCase.swift`:

- `cloneSampleFixture(into:)` (~line 127) — extend `pairExts` set
  to `["ARW", "HIF", "HEIF", "HEIC", "JPG", "JPEG", "xmp"]`.
- `sortedPairStems()` (~line 255) — mirror PairFinder's logic
  exactly: stems where (`ARW`+(`HIF`|`JPG`)) OR `HIF` OR `JPG`.

`PhotoXTests/PairFinderTests.swift` — add cases:

- ARW + JPG → 1 pair (previewURL ends `.JPG`, rawURL non-nil).
- ARW + HIF + JPG → 1 pair (previewURL ends `.HIF`, JPG ignored).
- JPG-only → 1 pair (rawURL nil).
- HIF-only → 1 pair.
- ARW-only → 0 pairs (still rejected).

Reuse existing test scaffolding — the file already exists per the
exploration.

Existing `XMPSidecarTests` / decoder tests don't need to change —
PhotoPair now optionally has `rawURL`, but the test fixtures
construct it explicitly.

## Critical files to modify

Renames in bold; the rest are JPG-support edits.

| File | What changes |
|---|---|
| **`PhotoX/Model/PhotoPair.swift` → `PhotoEntry.swift`** | Struct renamed, `rawURL: URL?`, `heifURL` → `previewURL`, add `xmpURL` + `hasJPGPreview` |
| **`PhotoX/Loading/PairFinder.swift` → `EntryFinder.swift`** | Enum renamed, `pairs(in:)` → `entries(in:)`, three-way tuple + HIF>JPG preference |
| **`PhotoX/Model/ImageVariant.swift`** | `.heif` → `.preview` (rawValue too) |
| **`PhotoX/Decoders/HEIFDecoder.swift` → `PreviewDecoder.swift`** | Type renamed; impl unchanged (ImageIO call already handles JPG) |
| **`PhotoX/Decoders/HIFBytesCache.swift` → `PreviewBytesCache.swift`** | Type renamed; impl unchanged (LRU on URL path) |
| `PhotoX/Shoot/Shoot.swift` | `pairs: [PhotoPair]` → `entries: [PhotoEntry]` |
| `PhotoX/Shoot/ShootScanner.swift` | Calls `EntryFinder.entries(in:)` |
| `PhotoX/Model/ViewerState.swift` | `PairFiles` → `EntryFiles` + `.jpg` field; rename `pair`/`displayedPair`/`pairXMPs`/`pairExif`/`pairSequenceNumber`/`currentPairFiles`; guards in `maybeAutoSwap` / `toggleRequestedVariant`; derive XMP path from `entry.xmpURL`; every `.heif` pattern → `.preview` |
| `PhotoX/Canvas/CanvasRenderer.swift` | `entry.previewURL` / `.preview` variant |
| `PhotoX/Decoders/DecodePipeline.swift` | `entry.previewURL`; `.preview` variant; route to `PreviewDecoder` / `PreviewBytesCache`; fall back `.raw` → `.preview` when `rawURL == nil` |
| **`PhotoX/Decoders/JPEGEmbeddedThumbnail.swift`** (new) | JPG header parser: APP1 → IFD0/IFD1 → embedded thumbnail bytes + EXIF TIFF |
| `PhotoX/Filmstrip/ThumbnailLoader.swift` | Dispatch HEIF/HEIC/HIF → `HEIFEmbeddedThumbnail`; JPG/JPEG → `JPEGEmbeddedThumbnail`; else ImageIO fallback. Propagate `previewURL` rename |
| `PhotoX/Filmstrip/FilmstripView.swift` | `state.pair` → `state.entry`; `entry.previewURL`; rename `displayedPair` reads |
| `PhotoX/Metadata/MetadataBatchLoader.swift` | `entry.previewURL` (exiftool handles JPG natively, no logic change) |
| `PhotoX/Shoot/FolderStats.swift` | Add JPG extensions to its sets; count entries with any preview |
| `PhotoX/Loading/OpenPanelCoordinator.swift` | Add JPG UTType + update message |
| `PhotoX/Export/ExportSettings.swift` | Doc-comment update on `includeHIF` (keep field name for storage compat) |
| `PhotoX/Export/ExportDestinationRow.swift` | Label "HIF" → "HIF/JPG" + help text |
| `PhotoX/Export/ExportPlanner.swift` | `entry.previewURL` (rename + cover JPG) |
| `PhotoX/Export/ExportRunner.swift` | `managedExtensions` adds `jpg`, `jpeg` |
| `PhotoX/ContentView.swift` | `filesBadge` 8-case switch; `statusText` derives format label from `entry.hasJPGPreview`; "ARW + HIF pairs" → "ARW + HIF/JPG pairs"; `state.pair` → `state.entry` |
| `PhotoX/PhotoXApp.swift` | Same string updates |
| `PhotoX/HelpOverlay.swift` | Z + ⌘O help-row text |
| `PhotoX/Settings/SettingsView.swift` | Auto-swap toggle label |
| `PhotoX/Sidebar/*.swift` | `state.entry` / `state.displayedEntry` reads, `entryXMPs` / `entryExif` |
| `README.md` | File requirements section + any HIF prose mentions |
| `PhotoXUITests/PhotoXUITestCase.swift` | `pairExts` (allow JPG/JPEG) + `sortedPairStems()` mirrors EntryFinder logic |
| `PhotoXTests/PairFinderTests.swift` → `EntryFinderTests.swift` | 5 new test cases (ARW+JPG, ARW+HIF+JPG, JPG-only, HIF-only, ARW-only) |

## Reuse / leverage

- `PreviewDecoder` (the renamed `HEIFDecoder`) is already
  ImageIO-based; accepts JPG bytes unchanged.
- `TIFFEXIFParser` is format-agnostic. The new
  `JPEGEmbeddedThumbnail` extracts the same TIFF block the HEIF
  path extracts and hands it to this parser unchanged. IFD1 walk
  for the thumbnail offsets is the only new TIFF logic — keep it
  inside `JPEGEmbeddedThumbnail` rather than bloating
  `TIFFEXIFParser` (it's a separate concern).
- `XMPSidecarWriter` already takes a `URL`; will receive
  `entry.xmpURL` instead of an inline-constructed path.
- `MetadataBatchLoader` (exiftool wrapper) is format-agnostic;
  reads JPG EXIF natively. Sony MakerNotes absent on JPG → AF
  overlay shows nothing, which is correct.

## Verification

1. `just build` clean.
2. `just test` — PhotoXTests green. New `PairFinderTests` cases
   exercise every pair combination.
3. `just dev` — manual smoke against the existing sample/ folder:
   - The DSC00060 stem (ARW + JPG) now appears as a pair. Pill
     shows `ARW+JPG`. Canvas statustext starts with "JPG …".
   - All other DSC pairs unchanged: pill shows `ARW+HIF`.
   - Open a folder of standalone JPGs (or temporarily drop in a
     JPG without an ARW sibling) and confirm it shows up as a
     JPG-only pair.
   - Press Z on a JPG-only pair — should no-op (no RAW to swap to).
     Ditto auto-swap by zooming.
4. `just e2e` — full XCUITest suite green. The fixture clone now
   includes `DSC00060.JPG`, the `sortedPairStems()` reports 58
   pairs instead of 57, and the smoke test still finds the first
   pair by sorted name.
5. Open the export sheet — toggle shows "HIF/JPG"; flip it off,
   run a small export, confirm preview files of both formats are
   skipped.
6. Production-prefs sanity (per the just-shipped E2E isolation):
   `dev.frostman.PhotoX.plist` sha unchanged after `just e2e`.

## Out of scope / follow-ups

- ARW-only pairs (no preview at all). The render path would need
  to decode RAW upfront, which defeats the whole HEIF-first design.
  Revisit if users actually have ARW-only shoots.
- JPG APP1 EXIF parser in the basic-EXIF pipeline (faster first-
  paint of sidebar metadata for JPG pairs). Advanced pipeline
  already covers it; this is just a latency win.
- `.heic` extension is already accepted (treated as HIF). No
  change needed.
- `HEIFEmbeddedThumbnail` rename — defer. It genuinely only parses
  HEIF's ISOBMFF; the name is correct.
