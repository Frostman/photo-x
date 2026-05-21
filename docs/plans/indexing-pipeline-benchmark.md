# Indexing pipeline benchmark CLI

## Context

The user observes that **NVMe SSD indexing is markedly slower than
CFExpress**, which is counterintuitive. We have no isolated way to
attribute that gap today — the production indexer runs all three
pipelines together inside `ViewerState`, behind SwiftUI, with fixed
batch sizes / worker counts wired as `static let` constants.

We need a standalone command-line benchmark that:

1. Exercises each indexing pipeline (basic-EXIF + thumbs, advanced
   EXIF via exiftool, XMP sidecar reader) in isolation.
2. Sweeps the three tunables — batch size, in-batch concurrency,
   cross-batch worker count — and reports per-combo wall time,
   throughput, and the existing `Stats` structs the loaders already
   produce.
3. **Is strictly read-only on the source folder.** The user will
   point it at non-replicable card / SSD data; nothing in the
   benchmark must write, rename, or `stat()`-touch anything beyond
   the read paths the production indexer already uses. (Matches the
   `card_readonly` and `global_rules` memories — applies to any
   user-provided path, not just `/Volumes`.)

The output should let the user compare the same sweep across two
folders (one NVMe, one CFExpress) and see exactly which pipeline +
which knob explains the gap.

## Approach

### Target shape

New **Xcode command-line tool target** `PhotoXBenchmark`, added to
`project.yml`. Builds via `xcodebuild`, runs from `just bench …`.

Why a tool target (not a `swift run` script or an XCTest perf test):

- Shares the exact production loader sources — no copy-paste drift
  between bench and app. A regression in the real indexer shows up
  in the benchmark immediately.
- Inherits the LibRaw / Obj-C bridging-header / exiftool-resource
  wiring from the existing target settings.
- XCTest's `measure { }` doesn't fit sweep-style parameter
  exploration (would need one test per combo) and runs Debug-config
  by default, masking the real numbers.

### Source set (carefully scoped, read-only by construction)

The bench target lists ONLY the loaders + their direct dependencies,
so the writer paths can't accidentally be called:

| Path | Role |
|---|---|
| `PhotoX/Loading/EntryFinder.swift` | folder → `[PhotoEntry]` |
| `PhotoX/Model/PhotoEntry.swift` | entry struct |
| `PhotoX/Model/BatchQueue.swift` | queue actor (already MainActor-free) |
| `PhotoX/Metadata/MetadataBatchLoader.swift` | advanced-EXIF pipeline loader |
| `PhotoX/Metadata/XMPSidecarReader.swift` | XMP pipeline loader |
| `PhotoX/Metadata/XMPSidecar.swift` | model |
| `PhotoX/Metadata/ExifSummary.swift` | model |
| `PhotoX/Metadata/AFRegion.swift`, `AFSettings.swift` | models |
| `PhotoX/Metadata/TIFFEXIFParser.swift` | used by ThumbnailLoader |
| `PhotoX/Metadata/ExifToolRunner.swift` | binary-path resolution + AFData type |
| `PhotoX/Metadata/ImageIOMetadata.swift` | referenced by parsers |
| `PhotoX/Filmstrip/ThumbnailLoader.swift` | basic-EXIF + thumb pipeline loader |
| `PhotoX/Decoders/HEIFEmbeddedThumbnail.swift` | HEIF fast-path |
| `PhotoX/Decoders/JPEGEmbeddedThumbnail.swift` | JPEG fast-path |
| `PhotoX/Util/Log.swift` | logger |
| `PhotoX/Util/OrientationApplier.swift` | used by ThumbnailLoader |
| `PhotoXBenchmark/*.swift` | new bench code |
| `Resources/exiftool/` | bundled binary (Copy Files build phase) |

`PhotoX/Metadata/XMPSidecarWriter.swift` is **deliberately NOT
linked** — if it's not in the target, it can't be called.

The bench target mirrors `PhotoX`'s `SWIFT_OBJC_BRIDGING_HEADER`,
`HEADER_SEARCH_PATHS`, and `OTHER_LDFLAGS` (for LibRaw) since the
transitive deps include the Obj-C++ bridge.

### New files

```
PhotoXBenchmark/
  main.swift            # @main entry; argument parsing; sweep driver
  BenchOptions.swift    # parsed CLI flags
  PipelineRunner.swift  # runs one (pipeline, params) combo, returns BenchResult
  BenchResult.swift     # per-run metrics struct
  Reporter.swift        # stdout table + optional CSV writer
```

`main.swift` is small: parse args, scan the folder via `EntryFinder`,
build the sweep matrix, run each combo, write the report.

### CLI surface

```
photox-bench <folder> [options]

  --pipeline basic|advanced|xmp|all       (default: all)
  --batch-sizes  N[,N…]                   (per-pipeline defaults below)
  --workers      N[,N…]                   (default: 1,2,4)
  --concurrency  N[,N…]                   (in-batch parallelism; default: 1,5)
  --max-files N                            (cap; default: all)
  --warmup                                  (run a throwaway pass first;
                                              page-cache priming. on by default)
  --no-warmup                               (disable warmup)
  --repeats N                               (default: 1; reports min/mean/max)
  --csv <path>                              (also write CSV)
```

Per-pipeline default sweep:

- **basic**: `batch-sizes=1,5,10,25,50`, `concurrency=1,2,5,10`, `workers=1,2`
- **advanced**: `batch-sizes=5,25,50,100,200`, `workers=1,2,4` (concurrency ignored — one subprocess per batch)
- **xmp**: `batch-sizes=1,25,50`, `concurrency=1,5,10`, `workers=1,2`

User can override any axis with the matching flag.

### Sweep driver

```swift
for combo in matrix {
    if options.warmup { _ = await runOnce(combo) }  // discard
    var results: [BenchResult] = []
    for _ in 0 ..< options.repeats {
        results.append(await runOnce(combo))
    }
    reporter.add(combo: combo, results: results)
}
reporter.print(to: stdout)
if let csv = options.csv { reporter.writeCSV(to: csv) }
```

`runOnce(combo)` constructs a `BatchQueue(batchCount: …)`, slices
`[PhotoEntry]` via `stride(from:to:by: batchSize)`, spawns `workers`
concurrent consumers each driving the loader for `pipeline`, joins,
records wall time + sum of per-batch `Stats`.

### Output

Stdout: one table per pipeline. Example:

```
basic-EXIF+thumbs — 4695 files, 1.42 GB
  batch  conc   workers   wall(s)  files/s   MB/s   p50_ms   p95_ms
      1     1        1     32.4     145    44.2      6.1      9.8
      5     5        1     12.1     388   118.6      5.7      9.4
      5     5        2      9.7     484   148.0      5.8      9.7
     25    10        2      8.9     527   161.1      ...
…
```

CSV (when `--csv` given) has one row per (pipeline, batch, conc,
workers, repeat) with the raw Stats sums alongside derived rates so
the user can graph in their tool of choice.

### Read-only guarantees

Belt-and-braces:

1. **Source set** excludes `XMPSidecarWriter.swift` — physical
   inability to write XMPs.
2. **No `Data.write`, `FileManager.removeItem`, `FileManager.moveItem`,
   `FileManager.createDirectory`** anywhere in `PhotoXBenchmark/`.
   A short unit test grep will keep that invariant.
3. **Banner on launch**: `"benchmarking <path> (read-only — no writes
   to source folder)"`.
4. **exiftool args** — `MetadataBatchLoader.tagArgs` already only
   contains read-side `-Tag` and `-Tag#` flags; no `-o`, no
   `-overwrite_original`. The bench reuses the production argv.

### `just bench` target

```just
# Run the indexing-pipeline benchmark against <folder>. Read-only:
# the benchmark never writes to the source folder.
#   just bench /Volumes/SD/DCIM/100SONY
#   just bench /Volumes/SD/DCIM/100SONY --pipeline advanced --batch-sizes 25,50,100
bench *args:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild -scheme PhotoXBenchmark -configuration Release \
        -destination 'platform=macOS' -quiet build
    BUILD_DIR="$(xcodebuild -scheme PhotoXBenchmark -configuration Release \
        -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
        | awk '/^[[:space:]]*BUILT_PRODUCTS_DIR = /{print $3; exit}')"
    "$BUILD_DIR/PhotoXBenchmark" {{args}}
```

Release config so the numbers are representative (Debug would make
the parsers ~3× slower and dominate the disk timings).

## Critical files to modify / create

| File | Change |
|---|---|
| `project.yml` | (a) Add `PhotoXBenchmark` target — type `tool`, explicit `sources:` list above, mirror PhotoX's bridging-header + LibRaw settings, add `Resources/exiftool` as a Copy Files phase. (b) Add a matching scheme so `xcodebuild -scheme PhotoXBenchmark` resolves. |
| `PhotoXBenchmark/main.swift` | New — entry point, arg parsing, sweep driver. |
| `PhotoXBenchmark/BenchOptions.swift` | New — parsed CLI flags + per-pipeline defaults. |
| `PhotoXBenchmark/PipelineRunner.swift` | New — runs one (pipeline, batchSize, conc, workers) combo. Reuses `BatchQueue`, `MetadataBatchLoader.readInstrumented`, `ThumbnailLoader.loadInstrumented`, `XMPSidecarReader.read`. |
| `PhotoXBenchmark/BenchResult.swift` | New — per-run metrics struct. |
| `PhotoXBenchmark/Reporter.swift` | New — stdout table formatter + CSV writer. |
| `Justfile` | New `bench *args:` recipe (above). |

No production-code edits. No new tests for bench output (it's a
diagnostic tool), but the read-only-grep invariant is worth a
single-line check in `scripts/bootstrap.sh` or a `just` recipe — TBD.

## Verification

1. `just bootstrap` — regenerates `PhotoX.xcodeproj` with the new target.
2. `just build` (app) still green — no production sources touched.
3. `just test` — full unit suite stays at 287/287.
4. `just bench sample/` — exercises the bench against the sample/
   fixture. Expected: bench runs to completion, prints a table per
   pipeline, no errors. (Sample is only ~144 files, so timings are
   noisy — useful as a smoke test, not a real benchmark.)
5. `just bench /path/to/big/NVMe-folder` and
   `just bench /path/to/big/CFExpress-folder` — the actual diagnostic
   runs. Capture both outputs, compare side-by-side. The expected
   outcome is identifying which pipeline + which knob explains the
   NVMe slowdown.
6. **Read-only sanity check**: before/after `git status` on the
   source folder shows no mtime / size changes. (If the source is
   outside a git repo, `find <folder> -newer …` works too.)

## Out of scope

- **Detecting storage type** (NVMe vs card) automatically — `df` /
  `diskutil info` parsing is flaky across mounts. The user labels
  each run via the folder path in the report header.
- **Memory profiling** — orthogonal; use Instruments if memory is
  the bottleneck.
- **Decoder pipeline** (RAWImageIO / RAWLibRaw / PreviewDecoder) —
  those are nav-time, not indexing. Out of scope here; add later if
  needed via a `--pipeline decode` flag.
- **Histogram visualization** — the CSV gives the user everything to
  plot in their tool of choice.
