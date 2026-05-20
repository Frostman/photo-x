# Culling table-stakes gap audit (pre-AI roadmap)

## Context

We started exploring AI culling helpers (sharpness, blink detection, best-of-burst, etc.) and stepped back to do market research first. The research surfaced a clear lesson — AI features only land on a strong base of "table-stakes" culling primitives (compare modes, filters, multi-select, jump-to-next-pick, etc.) — and the most-valued AI signals (blink flag, face panel, burst grouping) all assume those primitives exist. Lightroom Classic's late-2025 AI Assisted Cull and Aftershoot's over-selection are cited as proof that AI on a shaky base undermines trust.

This document is the **gap audit + prioritized roadmap** that informs which slice to build next. It is not an implementation slice in itself.

Source research is preserved at `~/.claude-frn/plans/let-s-explore-some-ai-crispy-duckling-agent-af89121889548db4d.md` (market findings on Aftershoot / Narrative / FilterPixel / Imagen / Excire / Photo Mechanic / OptiCull, pro photographer sentiment, academic/OSS references, and table-stakes feature list).

## Audit results

Status legend: ✅ shipped · 🟡 partial · ❌ missing.

### Navigation & advance
| Feature | Status | Evidence |
|---|---|---|
| Auto-advance on rate/label (opt-in) | ✅ | `ViewerState.swift:1276–1278, 1326–1328`, `SettingsKey.autoAdvance` / `.autoAdvanceSidebar` |
| First/last (Home/End) | ✅ | `ContentView.swift:162–168` → `firstPair()` / `lastPair()` |
| Continuous nav within filtered subset | ✅ | `ViewerState.swift:1149–1160` `nextVisibleIndex(from:direction:)` |
| Group-aware navigation (⌘←/→ between bursts) | ✅ | `ContentView.swift:144–160`, `ViewerState.navigateByBurst(direction:)` |
| **Jump to next pick / unrated / rejected** | ❌ | No `nextUnrated` / `nextPick` / `jumpTo` in code; pros' core keystroke missing |

### Selection
| Feature | Status | Evidence |
|---|---|---|
| **Multi-select (shift/cmd-click)** | ❌ | `FilmstripThumbnailView` only has `onTapGesture`, no modifier branches |
| **Bulk operation on selection** | ❌ | No multi-select state → no bulk apply |

### Filters & sort
| Feature | Status | Evidence |
|---|---|---|
| Filter by rating (per-star toggles) | ✅ | `ViewerState.showStars: Set<Int>`, `StatusBarView.swift:179–207` |
| Filter by rejected/unrated | ✅ | `ViewerState.showRejected: Bool` line 206 |
| Sort modes (name / score asc / score desc) | ✅ | `ViewerState.SortMode` lines 15–38 |
| Filter UI surface | 🟡 | Embedded in status bar; no filter bar / chips / sidebar |
| **Filter by color label** | ❌ | Labels are writable, no `showLabels` state, no `isVisible()` branch |
| **Filter by EXIF (lens, focal, ISO, time, camera)** | ❌ | `entryExif: [String: ExifSummary]` exists but no filter consumer |
| **Saved filter presets** | ❌ | Filters reset on app restart |

### Burst / group handling
| Feature | Status | Evidence |
|---|---|---|
| Burst collapse in filmstrip (with auto-expand of focused) | ✅ | `FilmstripView.swift:6, 39–48`, `StatusBarView.swift:20` |
| Group navigation (next/prev burst) | ✅ | See nav table above |
| **"Best of group" affordance** | ❌ | No designate-keeper UX |

### View modes
| Feature | Status | Evidence |
|---|---|---|
| Loupe / 1:1 zoom | ✅ | `CanvasViewport.swift:13, 24–26`; max scale 64 |
| Stay-zoomed across nav | ✅ | `ViewerState.swift:1119` `applyCurrentEntry(resetViewport: false)` |
| Zoom gestures (pinch / ⌘+scroll / dbl-click toggle) | ✅ | `ImageCanvasNSView.swift:237, 243–264` |
| Hide/show filmstrip + sidebar (T / B) | ✅ | `ContentView.swift:55–62`, `HelpOverlay.swift:50–51` |
| **Compare view A/B with synced zoom** | ❌ | Single-canvas architecture; no `HSplitView`, no `compare` |
| **Survey view N-up grid** | ❌ | Filmstrip is 1D ribbon only |

### Polish / pro
| Feature | Status | Evidence |
|---|---|---|
| Same-key-toggle clears rating | ✅ | `ViewerState.swift:1311` |
| Help overlay (?) | ✅ | `HelpOverlay.swift` + `ContentView.swift:170` |
| Background indexing progress + popover | ✅ | `StatusBarView.swift:32–49` |
| Recent shoots | ✅ | `Shoot/RecentShoots.swift`, `ContentView.swift:449, 629–651` |
| **General Cmd+Z undo for ratings** | ❌ | No `UndoManager` integration; only same-key toggle |
| **Customizable keybindings** | ❌ | 30+ `.onKeyPress(...)` calls hardcoded inline in `ContentView.swift:90–178`; would need extraction to a dispatcher |

### Headline shipped/missing counts
- Shipped: ~18
- Missing: 11
- Partial: 2

## Prioritized roadmap

Ranked by **value × effort × value-as-foundation-for-AI**. Each item is one independently-shippable slice.

### Tier 1 — Foundational gaps. Ship before any AI work.

| # | Slice | Why now | Est. effort | Foundation for |
|---|---|---|---|---|
| 1 | **Jump-to-next keystrokes** (next pick / next unrated / next rejected; opposites with Shift) | Photo Mechanic muscle memory; missing the single most common pro keystroke pattern; trivial extension of existing `nextVisibleIndex`. | ~2 h | All cull workflows |
| 2 | **Filter by color label** (parity with rating filter in status bar) | Color labels are already written; readers can't filter on them yet — asymmetry hurts the workflow we already half-ship. | ~2 h | "Find all yellow-tagged client picks" workflows |
| 3 | **Multi-select + bulk apply** (shift-click range, cmd-click toggle, then rating/label/reject applies to all) | Required for "reject all of this soft burst" and any future "best of group" UX. Unblocks Tier 2 #6 and #7. | ~1 day | Best-of-group, bulk reject |
| 4 | **EXIF filter chips** (lens, focal-length range, ISO range, time-of-day, drive mode, AF mode) + horizon/tilt filter using EXIF RollAngle | Lights up immediately, zero AI, zero new model trust issues, on data already loaded. Pros use these constantly in Photo Mechanic. | ~1.5 days | "Smart filters" framing |

### Tier 2 — High-impact view modes. Largest UX leap.

| # | Slice | Why | Est. effort |
|---|---|---|---|
| 5 | **Compare view A/B with synced zoom + pan** | Biggest single UX upgrade for cullers per the research. Burst review is hard without it. Universally cited as table-stakes. | ~2–3 days |
| 6 | **Survey view N-up grid** (2/3/4/5/6 selectable) | Lightroom's killer culling view for ranking N candidates. Less essential than A/B but high value once multi-select exists. | ~1.5–2 days |
| 7 | **"Best of group" affordance** (one keystroke promotes the current frame as the burst's keeper; sibling frames auto-rejected with explicit confirmation per burst) | Small effort once multi-select is in. Addresses the #1 pain point (burst review). Keeps user-in-the-loop framing the research insists on. | ~0.5 day after #3 |

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

**Tier 1 #1 — Jump-to-next keystrokes.** Smallest possible win, ships in an afternoon, immediately changes the muscle memory toward the Photo Mechanic workflow. It also creates a natural place to anchor future "next unrated soft" / "next blink" jumps once we layer AI on. No new state, no new UI, no new data — pure dispatcher extension.

After #1 lands, expected order: #2 → #3 (multi-select; biggest gating dependency for everything downstream) → #4 (EXIF filters; lights up the most "wow" without AI risk) → re-evaluate Tier 2 vs. revisiting AI.

## Critical files (for the next slice plan)

When we plan #1 in detail in a future session, the relevant files are:
- `PhotoX/Model/ViewerState.swift:1119, 1149–1160, 1185–1223` — nav infrastructure, `nextVisibleIndex`, `navigateByBurst`. New helpers slot in here.
- `PhotoX/ContentView.swift:90–178` — keystroke chain. New `.onKeyPress` blocks for the jump keys.
- `PhotoX/HelpOverlay.swift` — document the new shortcuts.
- `PhotoX/Model/ViewerState.swift:206–230` (filter state) — read-only; `isVisible(_:)` is the natural predicate to reuse for "next matching".

## Verification (when slice is executed)

The deliverable of *this* document is the audit + roadmap above; nothing to verify in code yet. When a slice ships:

1. `just dev` (rebuild + relaunch DerivedData build per project rule).
2. Open a known shoot with mixed ratings (some unrated, some 3+, some rejects).
3. Press the new jump keys; verify each lands on the right next pair, wraps correctly at the end, and respects current filter state.
4. Confirm `HelpOverlay` lists the new shortcuts.
