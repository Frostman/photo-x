# E2E (UI) tests for PhotoX

> **Note:** an earlier draft at `docs/phase-3c-ui-integration-tests.md` (Git LFS fixture approach, ~12 scenarios) covers the same ground from a different angle. This plan supersedes it for the first cut. Keep or delete the old doc separately.

## Context

PhotoX today has a healthy `PhotoXTests` unit suite (23 files, ~4 kLOC) covering metadata parsers, the export pipeline, caches, and the indexer, but no end-to-end coverage. Every release relies on manual confirmation in the dev build before commit (per the user-confirms-before-commit rule). We want a UI-automation layer that drives the real app the way a user would — launch, navigate, rate, toggle HEIF↔RAW, verify XMP got written — so future refactors don't silently break a top-level flow that the unit tests can't see.

The approach: a new **`PhotoXUITests`** XCUITest bundle, driven primarily through the app's existing keyboard shortcuts (which are first-class and well-defined). The app is auto-loaded into a temp-dir fixture via the existing `PHOTOX_SAMPLE_DIR` env hook (`PhotoX/Loading/SamplePathProvider.swift:8`), bypassing the `NSOpenPanel`. We add a small set of `.accessibilityIdentifier(...)` calls so tests can read the EXIF panel, status bar, and decisions panel without depending on text content. Each test ends by asserting a **strict no-mutation invariant**: every non-XMP file in the fixture is byte-identical to the source (size + mtime + sha256), and any `.xmp` files the app wrote/updated are well-formed XML containing the expected XMP namespace. This bakes the existing "no original-image mutation" global rule into automated CI rather than relying on code review.

## Approach in one paragraph

- **Test framework:** XCUITest (built-in, ships with Xcode, fully macOS-supported). One new test target `PhotoXUITests` declared in `project.yml`.
- **Fixture:** each test copies the **entire `sample/` folder** (all ARW/HIF pairs + any existing XMP sidecars) from the repo into a fresh per-test temp dir, points the app at it via the launch env var `PHOTOX_SAMPLE_DIR`, and tears it down after. Repo `sample/` is never written to. Stays hermetic to the project per the scripts-hermetic rule. The copy is non-trivial in size (~hundreds of MB of ARW/HIF) but it's a single `FileManager.copyItem` per test (≈1–3 s on APFS thanks to clone-on-write) and gives the indexer/cache real load to chew on.
- **No-mutation invariant (every test):** at `setUp` after the copy, snapshot a manifest of every non-XMP file in the temp dir (relative path, byte size, mtime in ns, sha256). At `tearDown`, re-walk the dir: every non-XMP file must match its manifest entry exactly. Any new file must be `.xmp`. Every `.xmp` (pre-existing or newly written) must parse as XML and contain the `adobe:ns:meta/` and/or `xmp:Rating`/`xmp:Label` markers expected of a Lightroom-compatible sidecar. Failure surfaces as the *test* failing — not a separate check.
- **Driving the app:** keyboard shortcuts wherever possible (`1`–`5` rate, `0` clear, `R` reject, `←`/`→` navigate, `⌥←`/`⌥→` step ±10, `Home`/`End`, `Z` HEIF↔RAW, `A`/`C`/`F` overlays, `S` sidebar, `T` filmstrip, `?` help, `⌘O` open, `⌘0` fit, `⌘E` export). XCUITest `XCUIElement.typeKey(_:modifierFlags:)` handles all of these reliably.
- **Assertions:** read text from the EXIF panel ("Filename: <name>"), the StatusBar (current index / total), and the decision chips (star count, reject flag, color label) via stable accessibility identifiers. The Metal canvas itself is treated as opaque — verification is via observable text side effects. Optional follow-up: snapshot tests for canvas rendering.
- **Sparkle:** disabled in E2E runs via launch arg so the auto-check timer can't pop a dialog mid-test.

## Files to create

### `PhotoXUITests/PhotoXUITestCase.swift` (new — base class)
Shared XCTestCase subclass with:
- `setUpWithError`: creates a temp dir, **copies the entire `sample/` folder** from the repo into it via `FileManager.copyItem` (APFS clone keeps this fast), snapshots a `[relPath: FileFingerprint]` manifest of every non-`.xmp` file (size, mtime in ns, sha256 of contents), launches `XCUIApplication()` with `launchEnvironment["PHOTOX_SAMPLE_DIR"] = tmp.path` and `launchArguments = ["-photoxDisableSparkle", "YES", "-photoxUITestMode", "YES"]`.
- `tearDownWithError`: terminate the app cleanly, then run `assertFixtureIntegrity()` *before* removing the temp dir (so a failure leaves the dir for inspection).
- `assertFixtureIntegrity()`: re-walks the temp dir; for each non-`.xmp` file, fails if size, mtime, or sha256 differs from the manifest. For each `.xmp` file (including newly created ones), fails if it doesn't parse as XML via `XMLDocument(contentsOf:options:)` or if the parsed doc lacks the expected XMP root namespace. Any newly seen non-`.xmp` filename → fail.
- `FileFingerprint`: a tiny `(size: Int64, mtimeNanos: Int64, sha256: Data)` struct. Helper `fingerprint(_ url: URL)` streams the file through `CryptoKit.SHA256` so even multi-hundred-MB ARWs don't balloon memory.
- Helpers: `app`, `tempFixtureURL`, `xmpSidecar(forPairNamed:)`, `currentEXIFFilename()`, `currentStatusBarIndex()`, `currentRating()`, `pressKey(_:modifiers:)`, `waitForShootLoaded(expectedCount:)`.

The repo `sample/` path resolves via `Bundle(for: PhotoXUITestCase.self)` walked up to the source root, exposed through a `#file`-derived constant — the test bundle doesn't *embed* the fixtures, it reads them from the dev tree at test time. This keeps the test bundle small and lets `sample/` evolve without bundle rebuilds.

### `PhotoXUITests/SmokeTests.swift` (new)
- `test_launch_loadsFixture_andShowsFirstPair`: app starts, EXIF panel populates, filmstrip non-empty, status bar shows `1 / N`.

### `PhotoXUITests/NavigationTests.swift` (new)
- `test_rightArrow_advancesByOne`: pressing `→` moves the status-bar index from `1 / N` to `2 / N`, and the EXIF filename row changes to the second pair's name (looked up via `ShootScanner.scan`-sorted order in the test).
- `test_leftArrow_goesBack`: `→ →` then `←` lands on index 2.
- `test_rightArrow_atEnd_wrapsOrStops`: navigate to the last index, press `→` once more, assert the observed behavior (test pins whichever the app actually does today so a future change to wrap behavior is loud).
- `test_optionArrow_stepsByTen`: `⌥→` moves index by exactly 10 (uses `XCUIKeyModifierFlag.option` + `.rightArrow`).
- `test_homeEnd_jumpToBoundaries`: `End` jumps to index `N`, `Home` to index `1`.
- `test_arrowSpam_doesNotCorruptIndex`: press `→` 50 times rapidly with `XCUIElement.typeKey` in a tight loop, then assert index equals `min(51, N)` (or expected wrap target). This catches off-by-one / dropped-event regressions that single-step tests miss.

### `PhotoXUITests/RatingTests.swift` (new)
- `test_starRating_writesXMPSidecar`: press `3` on the first pair → DecisionsPanel shows ★★★ → on disk, a `.xmp` next to the ARW contains `xmp:Rating>3`.
- `test_reject_flagsAndOptionallyAdvances`: `R` toggles the reject chip.
- `test_colorLabel_setAndClear`: `⇧3` (Green) sets the label chip; `⇧0` clears.

### `PhotoXUITests/ViewToggleTests.swift` (new)
- `test_heifRawToggle_updatesEXIFFilename`: `Z` flips the displayed file from `.HIF` to `.ARW` (visible in EXIF panel — auto-swap is one-way per the existing rule, so test asserts that direction).
- `test_sidebarAndFilmstrip_toggleVisibility`: `S` hides sidebar, `T` hides filmstrip, both restored.

### `PhotoXUITests/IndexingTests.swift` (new)
- `test_indexer_findsEveryPair`: after launch, wait for the status bar's total label to settle, assert it equals `ShootScanner.scan(folder: tmpFixture).pairs.count` (the test re-runs the scanner against the temp dir to compute the expected count — same code the app uses, so this catches the indexer dropping or duplicating pairs).
- `test_indexer_populatesEXIFForEveryPair`: step through all N pairs with `→`; for each one, assert the EXIF panel's `exif.row.filename`, `exif.row.iso`, `exif.row.shutter`, `exif.row.aperture` rows all populate (non-empty, non-"—") within a 2 s wait. Catches regressions where the indexer keeps up with one direction but stalls on the other.
- `test_indexer_handlesPreExistingXMP`: before launch, the test writes a known-good `.xmp` sidecar next to one pair (rating=4, label=Green) by templating a minimal Lightroom-compatible XMP. After launch, navigates to that pair, asserts the DecisionsPanel shows ★★★★ + Green label — proves the indexer reads existing decisions on first index, not just on demand.

### `PhotoXUITests/CachingTests.swift` (new)
- `test_backwardNav_doesNotRedecode`: navigate forward through 10 pairs, then backward to pair 1. Assert that during the backward sweep, the `canvas.loadingIndicator` accessibility element (gated behind the existing user-controlled toggle — test enables it via launch arg / UserDefaults) is never visible for more than a transient frame on any already-visited pair. A working LRU/texture cache should serve those instantly.
- `test_filmstripScroll_buildsThumbnails`: assert filmstrip thumbs for the visible window populate within 5 s of launch (querying `filmstrip.thumb.<i>` existence + readiness), and remain present after scrolling to the end and back — i.e., the thumb cache isn't evicted under normal navigation. Bounded by the user-visible filmstrip viewport, not "every thumb in N pairs".
- `test_repeatedToggle_doesNotLeak`: press `Z` (HEIF↔RAW) 20 times on the same pair, then assert subsequent `→`/`←` navigation still feels responsive (each navigation completes within 1.5 s wall-clock; XCUITest's `waitForExistence` covers this). Sniffs for a cache-leak / texture-pile-up regression where the canvas slows down over a long session.

### `PhotoXUITests/Fixtures/` (empty — fixtures sourced from `sample/` at runtime)
Kept as a directory placeholder so XcodeGen sees it; actual pair files are copied from repo `sample/` per test.

## Files to modify

### `project.yml` (add a third target — after `PhotoXTests` at line 136)
```yaml
  PhotoXUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: PhotoXUITests
    dependencies:
      - target: PhotoX
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.frostman.PhotoXUITests
        GENERATE_INFOPLIST_FILE: YES
        TEST_TARGET_NAME: PhotoX
```
And add `PhotoXUITests: [test]` to the `schemes.PhotoX.build.targets` list (line 153 area) plus `- PhotoXUITests` under `schemes.PhotoX.test.targets`.

### `Justfile` (add target after `test`)
```just
# Run the E2E suite. Slower than `just test` because each test launches
# the real app and copies the full sample/ fixture into a temp dir.
#   just e2e                                  → full E2E suite
#   just e2e PhotoXUITests/SmokeTests         → one class
#   just e2e PhotoXUITests/RatingTests/test_starRating_writesXMPSidecar → one method
e2e *only="":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS=(test -scheme PhotoX -configuration Debug -destination 'platform=macOS' -only-testing:PhotoXUITests)
    for filter in {{only}}; do
        ARGS+=(-only-testing:"$filter")
    done
    # E2E tests can hang if a permission dialog pops or the app deadlocks;
    # cap at 10 min — the full sample/ copy + indexing + nav sweeps take
    # longer than the unit suite, but anything over 10 min is a hang.
    timeout 600 xcodebuild "${ARGS[@]}"
```
`just test` stays unit-only (60 s cap) and remains the fast pre-commit check; E2E runs are explicit via `just e2e`.

### `PhotoX/Loading/SamplePathProvider.swift` — no changes
The existing `PHOTOX_SAMPLE_DIR` env var path (lines 8–9) is exactly the injection point we need.

### `PhotoX/PhotoXApp.swift` — small addition (UI-test mode flag)
Read `-photoxDisableSparkle YES` at launch and skip `UpdaterController()` construction (or call `updater.suspend()`) when set. Same for the launch-time window-maximize side effect that interferes with XCUITest's expectations of a default frame — gated by `-photoxUITestMode YES`. ~10 lines.

### Selective `.accessibilityIdentifier(...)` additions (~10–15 sites)
Goal: stable hooks for assertions without coupling tests to user-facing text.

- `PhotoX/Sidebar/ExifPanelView.swift` — wrap each row in an identified container: `exif.row.filename`, `exif.row.iso`, `exif.row.shutter`, `exif.row.aperture`, `exif.row.lens` (5 ids).
- `PhotoX/Sidebar/DecisionsPanelView.swift` — `decisions.star.<n>` (n=0..5), `decisions.reject`, `decisions.label.<color>` on the chip buttons.
- `PhotoX/StatusBarView.swift` — `statusbar.indexLabel`, `statusbar.totalLabel`, `statusbar.shootName`.
- `PhotoX/Filmstrip/FilmstripView.swift` — `filmstrip.thumb.<index>` on each thumb (computed in the ForEach), `filmstrip.container`.
- `PhotoX/Sidebar/SidebarView.swift` — `sidebar.container`.
- `PhotoX/HelpOverlay.swift` — `help.overlay`.

These are inert at runtime (no behavior change), but turn the SwiftUI tree into something XCUITest can navigate by stable name.

### `.gitignore` — add `PhotoXUITests/.tmp/` (defensive; tests use NSTemporaryDirectory but a stray local-temp pattern is cheap insurance).

## Functions / utilities to reuse

- `ShootScanner.scan(folder:)` (referenced from `PhotoXApp.swift:96`) — the test base class can call it to verify it sees the expected pair count in the temp fixture, mirroring real app behavior.
- `XMPSidecar` (covered in unit tests) — the rating-writes-XMP assertion can re-use the same sidecar reader to parse what the app wrote.
- `AppDefaults.shared` + `SettingsKey` — base class can clear UI-test-relevant defaults at setUp to keep tests deterministic.
- `PHOTOX_SAMPLE_DIR` env hook (`PhotoX/Loading/SamplePathProvider.swift:8`) — already there, no new injection mechanism needed.

## Verification

1. `xcodegen` regenerates the project with the new target (`just bootstrap`).
2. `just build` still passes (compile-check of the new app-code changes).
3. `just test` (unit) still passes in <60 s — E2E tests are excluded from this target.
4. `just e2e` runs the new bundle end-to-end. Expected: every test in Smoke, Navigation, Rating, ViewToggle, Indexing, Caching passes (~14 tests total). Total wall time targeted under 5 min on Apple Silicon (each test ≈15–25 s: full `sample/` clone + app launch + indexing + a sweep of keystrokes + integrity check).
5. **The no-mutation invariant is the load-bearing one** — verify by hand once: deliberately mutate a HIF file inside `assertFixtureIntegrity()` (e.g., append a byte) and confirm the test fails with a clear "fixture mutated" message that names the offending file. Then revert.
6. **Manual confirmation step before commit** (per the user-confirms-before-commit rule): show the `just e2e` summary, the new test names, and a `git status` diff; wait for explicit "works" before staging.
7. Spot-check: after `just e2e`, `git status -s` shows no changes to `sample/` (the temp-dir fixture isolation is what guarantees this; the integrity check inside the test is the belt; this is the suspenders).

## Out of scope (call out, defer)

- **Canvas pixel verification** (snapshot tests of the Metal output). Worth a follow-up using `pointfreeco/swift-snapshot-testing`, but introduces a third-party dep and image-diff tolerance tuning — not in this first cut.
- **Export sheet flow** (sheet, destination picker, runner). Doable, but the destination picker is another `NSOpenPanel` and the runner writes to disk; deserves its own focused PR with proper destination sandboxing.
- **GitHub Actions CI**. There is no `.github/workflows/` today. Wiring `just e2e` into CI is straightforward (`macos-26` runner, `just bootstrap && just test && just e2e`), but signing/notarization isn't needed for E2E runs so it's a small but separate change.
- **Zoom / pan gesture tests**. XCUITest can synthesize click+drag, but pinch/two-finger pan is awkward to simulate reliably. Defer until we hit a regression worth catching.
- **Multi-shoot / recents menu / favorites** — covered by "broad coverage" tier the user declined; revisit if the main flows shake loose enough bugs.
