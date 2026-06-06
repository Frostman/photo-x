# CLI indexer + cache-friendly indexing redesign (parked)

This branch holds work-in-progress for offloading shoot indexing to a Linux
NAS-side `photox` CLI and reshaping the macOS indexer around its sidecar
output. **Parked** as of 2026-06-06 — the redesign caused noticeable UI
slowdowns during thumbnail decoding without a corresponding progress
signal, and the user chose to abandon it for now rather than continue
iterating. `master` is reset back to a clean state.

## What shipped on this branch (committed)

Nine commits ahead of `origin/master`:

1. **CLI scaffold** — `CLI/` SwiftPM package with `IndexingCore` library +
   `photox` executable + `IndexingCoordinator.run` orchestrator.
2. **Linux cross-compile** — `just linux-build` / `just linux-deploy`
   targets, swift.org toolchain via `swiftly`, static Linux SDK install.
3. **PosixExec** — raw `fork + execve` via Musl, bypasses
   `Foundation.Process` EACCES on NixOS Nix-store paths.
4. **Sidecar schema** — `ShootSidecarIndex` binary plist (version 1) with
   `IndexFingerprint` (size + mtime nanos, ±1 s tolerance, size-only Hashable).
5. **macOS sidecar consumption** — `IndexerCache.setSidecarPayload` +
   two-payload cache (sidecar wins, local fills gaps, macOS never writes
   back to sidecar). 10 parity tests.
6. **Single-listing shoot scan** — `Shoot` gained `previewFingerprints` and
   `xmpStems`. `ShootScanner.scan` harvests both from one
   `contentsOfDirectory(at:includingPropertiesForKeys:)` call. Eliminated
   ~20k SMB stats on open. `runXMPPipeline` gates on `xmpStems`.
7. **Status chip + popover** — `loadingShoot` chip case, sidecar /
   localCache / miss split in popover.
8. **CLI diagnose subcommand** — `photox diagnose <folder>` for fingerprint
   debugging.
9. **No-sidecar parity tests** — pins existing cache behaviour when no
   sidecar is present.

## What's in the staged-but-uncommitted diff

The cache-friendly indexer redesign (Stages 14–17 from the task list):

- `IndexingWorkPlan` struct (file-local to `PhotoX/Model/IndexingPlan.swift`)
  — single MainActor pass that buckets every entry into
  `cachedThumbBytes / needsBasicFetch / needsAdvancedExif / needsXMP`
  plus prepopulated EXIF / AF / sequenceNumber maps and
  sidecarHits / localCacheHits / misses counts.
- `IndexingFlushBuffer<Item>` actor — 300 ms strict-cadence flush gate so
  each stream invalidates SwiftUI at most ~3 ×/s.
- `AsyncCursor<Item>` actor — shared FIFO for parallel decode workers.
- `runThumbDecodePipeline` (Stream A) — pure-CPU decode of cached JPEG
  bytes on `ProcessInfo.processorCount` workers.
- `runBasicExifAndThumbsPipeline` (Stream B), `runAdvancedExifPipeline`
  (C), `runXMPPipeline` (D) operate on plan-determined slices, not the
  full shoot.
- `isUserMutationLocked` + early-return gates on `setRating`, `setLabel`,
  `setRating(_:for:)`, `reIndex`, popover Delete-cache / Re-index buttons
  while indexing runs.
- `StatusBarView` popover renders 🔒 "Indexing — shoot is read-only"
  instead of action buttons during indexing.
- New tests: `IndexingWorkPlanTests` (7 bucket-allocation cases),
  `ViewerStateMutationLockTests` (lock invariant + gated handler tests).

## Why it was parked

On a fully sidecar-covered NAS shoot the redesign opens "eventually" but
with two unresolved UX problems:

1. **App unresponsive during Stream A decode.** Cached JPEG decode runs on
   N CPU workers at default task priority. On a 10k-entry shoot this
   saturates the CPU for several seconds. The 300 ms flush throttle keeps
   the main actor from being hammered, but the decode workers themselves
   still preempt UI work. Worker count and QoS were never tuned.
2. **No progress signal for the decode pipeline.** The popover progress
   bar tracks `basicExifAndThumbs / advancedExif / xmpSidecars` — Stream A
   has no counter wired into `progressTicker`, so the chip can hit
   100 % while the decode pool still has thousands of items left, and the
   user sees an unresponsive app with no explanation. `progressTicker`
   also exits its loop once basic + advanced + XMP are done, freezing the
   percent until Stream A finally completes (when `finishIndexing` runs).

## Pending work if resumed

In rough order:

1. **Surface Stream A in the progress UI.** Add `cachedThumbs: Double` to
   `IndexingProgress`, a corresponding `PipelineTiming`, a thread-safe
   counter (reuse `BatchQueue(batchCount: decodeCount)` and call
   `markDone` per item, or a small actor counter), and a new row in the
   popover. Include cachedThumbs in the ticker's "done" check so the loop
   doesn't exit early.
2. **Tame Stream A's CPU footprint.** Drop workers to
   `max(1, processorCount - 2)` and pin the decode tasks to `.utility` so
   the main thread always wins. Measure on a real shoot before adding
   per-stem prioritization (`ship-simple-measure-first` memory applies).
3. **Re-weight `IndexingProgress.total`.** Once cachedThumbs is in the
   mix the existing 0.15 / 0.75 / 0.10 weights need a re-derivation
   against measured wall times.
4. **Fix the three counter / ticker bugs that landed in the last edits**
   (already applied locally — verify they survived):
   - Advanced pipeline no longer double-bumps cache counters
     (`_ = batchSidecarHits / _ = batchLocalHits`).
   - `progressTicker` uses `xmpBatchCount` as the XMP denominator and
     done-check.
   - `reIndex` restores `entryFingerprints = shoot.previewFingerprints`
     after `cache.clearInMemory()`.
5. **Stage 8** — end-to-end NAS verification with the redesigned pipeline.
6. **Stage 18** — finish StatusBarView read-only hint + tests + e2e.

## Hard constraints carried from project memory

- Original images are never mutated; XMP sidecars hold culling data.
- SD/CFExpress cards under `/Volumes` are strictly read-only.
- Versions are derived from git (not hand-bumped).
- XMP write reliability is the #1 project goal — every write goes through
  `XMPWriteCoordinator`.
- No `exiftool -stay_open` via `Foundation.Process` (4 KB stdout buffer
  stall); per-batch one-shot spawns only.
- macOS app keeps using its embedded `Resources/exiftool/`; NAS CLI uses
  system exiftool from PATH via PosixExec.
- Release builds only log errors / warnings / lifecycle; per-frame and
  per-entry logs gate `#if DEBUG`.
