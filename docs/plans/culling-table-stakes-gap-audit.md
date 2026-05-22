# Culling table-stakes gap audit (pre-AI roadmap)

## Context

We started exploring AI culling helpers (sharpness, blink detection, best-of-burst, etc.) and stepped back to do market research first. The research surfaced a clear lesson — AI features only land on a strong base of "table-stakes" culling primitives (compare modes, filters, multi-select, jump-to-next-pick, etc.) — and the most-valued AI signals (blink flag, face panel, burst grouping) all assume those primitives exist. Lightroom Classic's late-2025 AI Assisted Cull and Aftershoot's over-selection are cited as proof that AI on a shaky base undermines trust.

This document is the **gap audit + prioritized roadmap** that informs which slice to build next. It is not an implementation slice in itself.

Source research is preserved at `~/.claude-frn/plans/let-s-explore-some-ai-crispy-duckling-agent-af89121889548db4d.md` (market findings on Aftershoot / Narrative / FilterPixel / Imagen / Excire / Photo Mechanic / OptiCull, pro photographer sentiment, academic/OSS references, and table-stakes feature list).

**Refreshed 2026-05-22.** Since the original audit, two roadmap items shipped (Tier 1 #1 partially — unrated jump only; Tier 2 #7 in full — `rejectBurstSiblings` via `g`). Line refs throughout have been re-anchored to current code.

## Audit results

Status legend: ✅ shipped · 🟡 partial · ❌ missing.

### Navigation & advance
| Feature | Status | Evidence |
|---|---|---|
| Auto-advance on rate/label (opt-in) | ✅ | `ViewerState.swift:1465–1466, 1535–1536` via `autoAdvanceAfterRating(source:)`, `SettingsKey.autoAdvance` / `.autoAdvanceSidebar` |
| First/last (Home/End) | ✅ | `ContentView.swift:217–220` → `ViewerState.firstPair()` / `lastPair()` at lines 1266 / 1274 |
| Continuous nav within filtered subset | ✅ | `ViewerState.swift:1285` `nextVisibleIndex(from:direction:)` |
| Group-aware navigation (⌘←/→ between bursts) | ✅ | `ContentView.swift:178–203`, `ViewerState.navigateByBurst(direction:)` at 1404 |
| **Jump to next unrated** | ✅ | `ViewerState.nextUnrated()` / `previousUnrated()` at 1377–1378, bound to `]` / `[` in `ContentView.swift:225–232` |
| **Jump to next pick / rejected** | ❌ | Only unrated direction wired; "next rated" and "next rejected" still missing. Cheap to add — same `nextVisibleIndex` + filter pattern as `walkRated`. |

### Selection
| Feature | Status | Evidence |
|---|---|---|
| **Multi-select (shift/cmd-click)** | ❌ | `FilmstripThumbnailView` only has `onTapGesture`, no modifier branches |
| **Bulk operation on selection** | ❌ | No multi-select state → no bulk apply |

### Filters & sort
| Feature | Status | Evidence |
|---|---|---|
| Filter by rating (per-star toggles) | ✅ | `ViewerState.showStars: Set<Int>` at 224, status-bar UI in `StatusBarView.swift:191–230` |
| Filter by rejected/unrated | ✅ | `ViewerState.showRejected` / `showUnrated` at 220–221 |
| Sort modes (name / score asc / score desc) | ✅ | `ViewerState.SortMode` lines 15–38; cached via `sortedEntries` at 164 |
| Filter UI surface | 🟡 | Embedded in status bar; no filter bar / chips / sidebar |
| **Filter by color label** | ❌ | Labels are writable, no `showLabels` state, no `isVisible()` branch |
| **Filter by EXIF (lens, focal, ISO, time, camera)** | ❌ | `entryExif: [String: ExifSummary]` exists but no filter consumer |
| **Saved filter presets** | ❌ | Filters reset on app restart |

### Burst / group handling
| Feature | Status | Evidence |
|---|---|---|
| Burst collapse in filmstrip (with auto-expand of focused) | ✅ | `FilmstripView.swift:6–7` `@AppStorage collapseBursts`; filter at line 43; status-bar button in `StatusBarView.swift` |
| Group navigation (next/prev burst) | ✅ | See nav table above |
| **"Best of group" affordance** | ✅ | `g` shortcut rejects burst siblings, leaving current as the keeper. `ViewerState.rejectBurstSiblings(scope:)` at 1580, wired in `ContentView.swift:236–242`. Scope (`.unrated` vs `.all`) configurable via `SettingsKey.gRejectScope`. |

### View modes
| Feature | Status | Evidence |
|---|---|---|
| Loupe / 1:1 zoom | ✅ | `CanvasViewport.swift`; max scale 64 |
| Stay-zoomed across nav | ✅ | `ViewerState.applyCurrentEntry(resetViewport:)` at 1695 — only `loadShoot`/explicit reset clears viewport |
| Zoom gestures (pinch / ⌘+scroll / dbl-click toggle) | ✅ | `ImageCanvasNSView.swift` mouse + scroll handlers |
| Hide/show filmstrip + sidebar (T / B) | ✅ | `ContentView.swift:157–162` (`t`/`T`), `HelpOverlay.swift` |
| **Compare view A/B with synced zoom** | ❌ | Single-canvas architecture; no `HSplitView`, no `compare` (confirmed by grep — zero references) |
| **Survey view N-up grid** | ❌ | Filmstrip is 1D ribbon only |

### Polish / pro
| Feature | Status | Evidence |
|---|---|---|
| Same-key-toggle clears rating | ✅ | `ViewerState.toggleRating(_:source:)` around 1614 |
| Help overlay (?) | ✅ | `HelpOverlay.swift` + `?` binding in `ContentView.swift` |
| Background indexing progress + popover | ✅ | `StatusBarView.swift:38–60` |
| Recent shoots | ✅ | `Shoot/RecentShoots.swift`, `ContentView.swift` Open Recent menu |
| **General Cmd+Z undo for ratings** | ❌ | No `UndoManager` integration (grep: zero `UndoManager` / `registerUndo` refs); only same-key toggle |
| **Customizable keybindings** | ❌ | 30+ `.onKeyPress(...)` calls hardcoded inline in `ContentView.swift:90–245`; would need extraction to a dispatcher |

### Headline shipped/missing counts
- Shipped: ~20 (+2 since original audit: jump-to-next-unrated, reject-burst-siblings)
- Missing: 9
- Partial: 3 (filter UI surface; jump-to-next pick/rejected halves; status-bar embedded filter)

## Prioritized roadmap

Ranked by **value × effort × value-as-foundation-for-AI**. Each item is one independently-shippable slice.

### Tier 1 — Foundational gaps. Ship before any AI work.

| # | Slice | Status | Why now | Est. effort | Foundation for |
|---|---|---|---|---|---|
| 1a | **Jump-to-next unrated** (`]` / `[`) | ✅ shipped | Photo Mechanic muscle memory; the single most common pro keystroke pattern. | (done) | — |
| 1b | **Jump-to-next pick** (next ≥ 1★ via Shift+`]`) and **next rejected** | ❌ remaining | Round out the keystroke set; same `nextVisibleIndex` + filter pattern as `walkRated`. | ~1 h | Symmetrical cull workflows |
| 2 | **Filter by color label** (parity with rating filter in status bar) | ❌ | Color labels are already written; readers can't filter on them yet — asymmetry hurts the workflow we already half-ship. | ~2 h | "Find all yellow-tagged client picks" workflows |
| 3 | **Multi-select + bulk apply** (shift-click range, cmd-click toggle, then rating/label/reject applies to all) | ❌ | Required for general bulk operations and any future review-N-then-decide UX. Unblocks Tier 2 #6. | ~1 day | Survey view, bulk reject |
| 4 | **EXIF filter chips** (lens, focal-length range, ISO range, time-of-day, drive mode, AF mode) + horizon/tilt filter using EXIF RollAngle | ❌ | Lights up immediately, zero AI, zero new model trust issues, on data already loaded. Pros use these constantly in Photo Mechanic. | ~1.5 days | "Smart filters" framing |

### Tier 2 — High-impact view modes. Largest UX leap.

| # | Slice | Status | Why | Est. effort |
|---|---|---|---|---|
| 5 | **Compare view A/B with synced zoom + pan** | ❌ | Biggest single UX upgrade for cullers per the research. Burst review is hard without it. Universally cited as table-stakes. | ~2–3 days |
| 6 | **Survey view N-up grid** (2/3/4/5/6 selectable) | ❌ | Lightroom's killer culling view for ranking N candidates. Less essential than A/B but high value once multi-select exists. | ~1.5–2 days |
| 7 | ~~**"Best of group" affordance**~~ | ✅ shipped | `g` shortcut rejects burst siblings (keeper stays focused). `GRejectScope` setting picks `.unrated` (default) vs `.all`. Addresses the #1 burst-review pain point per the original audit. | (done) |

### Tier 3 — Polish; defer.

| # | Slice | Why deferred | Est. effort |
|---|---|---|---|
| 8 | **Saved filter presets** | Nice-to-have; quarter-day; do once #2 and #4 exist. | ~0.25 day |
| 9 | **General Cmd+Z undo via `UndoManager`** | Sprawling — touches every mutation site. Same-key-toggle already covers the most common mistake. | ~1 day |
| 10 | **Customizable keybindings** | Largest refactor (extract dispatcher from 30 `.onKeyPress` calls). Current defaults are reasonable. Skip until pros complain. | ~1.5 days |

### Explicitly not in this roadmap (rationale)

- **All AI features (sharpness pill, blink detection, face panel, near-dup, best-of-burst auto-pick, aesthetic scoring, semantic search)** — deferred. Research is clear: AI on a shaky base undermines trust. Revisit after at least Tier 1 ships.
- **Auto-reject / auto-cull** — universally distrusted per research; not planned at all.
- **AI editing** — different product category.
- **Cross-shoot face recognition** — DAM territory; out of scope.

## Recommended next slice

**Tier 1 #2 — Filter by color label.** With #1a (unrated jump) and #7 (best-of-group) shipped, the next-smallest foundational gap is color-label filtering. Asymmetric today: we WRITE labels via the sidebar / `!`-`%` shortcuts but can't FILTER on them. ~2 hours work — add `showLabels: Set<String>` alongside `showStars`, extend `isVisible(_:)`, add per-label toggles to the existing status-bar `toggles` block.

#1b (next-pick / next-rejected) is even smaller (~1 h) but lower value — the unrated jump is the keystroke users actually want; pick/rejected are nice-to-haves.

After #2: jump to #3 (multi-select; biggest gating dependency for survey view and any future bulk-apply UX) → #4 (EXIF filters; lights up the most "wow" without AI risk) → re-evaluate Tier 2 vs. revisiting AI.

## Critical files (for the next slice plan)

When we plan #2 (color-label filter) in detail in a future session, the relevant files are:
- `PhotoX/Model/ViewerState.swift:218–244` — `RatingCategory`, `ratingCategory(for:)`, `isVisible(_:)`. Extend with a label category + show-set.
- `PhotoX/Model/ViewerState.swift:220–224` — filter state (`showStars`, `showRejected`, `showUnrated`). Add `showLabels: Set<String>` alongside.
- `PhotoX/Model/ViewerState.swift:283–290` — `shootStats` + `shownCount`. Extend to include per-label counts.
- `PhotoX/StatusBarView.swift:191–230` — `toggles` view. Mirror the per-star toggle pattern for per-label.
- `PhotoX/Metadata/XMPSidecar.swift` — `label: String?` is already the source of truth. No model change needed.

For #1b (next-pick / next-rejected) if we ship it alongside:
- `PhotoX/Model/ViewerState.swift:1377–1390` — `nextUnrated` / `walkRated`. Add `nextPick` / `nextRejected` siblings calling `walkRated` with a predicate.
- `PhotoX/ContentView.swift:225–232` — `]` / `[` bindings. Add Shift variants (`}` / `{`) for pick.
- `PhotoX/HelpOverlay.swift` — document the new keys.

## Verification (when slice is executed)

The deliverable of *this* document is the audit + roadmap above; nothing to verify in code yet. When a slice ships:

1. `just dev` (rebuild + relaunch DerivedData build per project rule).
2. Open a known shoot with mixed state (some unrated, some 3+, some rejects, some color-labeled).
3. For #2 (color-label filter): toggle each label off in the status bar; verify only entries with the remaining labels show in the filmstrip; verify the count chip updates. Run interaction with rating filters to ensure the AND-semantics match the existing rated/unrated/rejected behaviour.
4. For #1b: press Shift+`]` on an unrated entry and confirm it lands on the next ≥ 1★ pair; press Shift+`[` for previous; same against rejected via whatever shortcut we pick.
5. Confirm `HelpOverlay` lists the new shortcuts.
