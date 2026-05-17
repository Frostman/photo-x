# Phase 3c — End-to-end Integration Tests (XCUITest + Git LFS fixtures)

## Context

PhotoX has 84 unit tests covering pure logic (XMP round-trip, viewport math, EXIF parsers, pair scanning, etc.) but **zero coverage of the actual user-facing workflow** — launch, load a shoot, navigate, rate, swap variant, toggle filters, etc. A unit-test passing doesn't tell us whether ⌥+→ skips 10 pairs in the running app, whether pressing 3 actually writes `<stem>.xmp`, or whether Z swaps HEIF↔RAW end-to-end.

This phase adds **XCUITest-based integration tests** that drive the real `.app` against committed sample shoots, verifying every user-visible behaviour we care about. Local-only for now (no CI). Run via `xcodebuild test` alongside the existing unit suite.

## Decisions locked in

| Area | Decision |
|---|---|
| Test framework | **XCUITest** — Apple's standard, integrates with `xcodebuild test`, drives the real `.app` via accessibility APIs |
| Fixture size | **20 ARW+HIF+XMP pairs (~1.3 GB) committed via Git LFS** under `fixtures/integration/` |
| Test scope | **Comprehensive (~12 scenarios)** — smoke, navigation, ratings, label, reject, filter toggles, variant swap, sidebar/filmstrip visibility, About panel, settings persistence |
| Where | **Local-only via `xcodebuild test`**, wired into the existing scheme. GitHub Actions deferred. |
| Visual regression | **Not now** — assertions only on UI state (text, presence, accessibility values). Snapshot testing deferred. |
| Fixture isolation | Tests that write XMP get a **per-test copy** of the fixture folder under `NSTemporaryDirectory` so the committed LFS files are never modified |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  xcodebuild test  (PhotoX scheme)                                   │
│                                                                     │
│  ┌────────────────────────┐    ┌────────────────────────────────┐   │
│  │ PhotoXTests            │    │ PhotoXUITests   (NEW)          │   │
│  │ (bundle.unit-test)     │    │ (bundle.ui-testing)            │   │
│  │ 84 existing tests      │    │ 12 new scenarios               │   │
│  └────────────────────────┘    └────────────┬───────────────────┘   │
│                                              │ launches via         │
│                                              │ XCUIApplication      │
│                                              ▼                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ PhotoX.app  (Debug build)                                    │   │
│  │   PHOTOX_SAMPLE_DIR=$tmpFixtureCopy  (set per test)          │   │
│  │   + accessibility identifiers on toolbar / sidebar / status  │   │
│  │   + #if DEBUG test-probe views exposing currentStem,         │   │
│  │     displayedVariant, sidebarVisible, etc.                   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  fixtures/integration/    (Git LFS — 20 pairs, ~1.3 GB)             │
│      DSC04177.ARW, DSC04177.HIF, DSC04177.xmp,                      │
│      DSC04178.ARW, ...                                              │
└─────────────────────────────────────────────────────────────────────┘
```

### How tests talk to the running app

- **Inputs**: `XCUIApplication.typeKey` for keyboard, `.menuItems[]` for menu commands, `.buttons[id]` for toolbar/sidebar buttons via accessibility identifier.
- **Outputs**: visible text in title bar / status bar / score pills + `accessibilityValue` on lightweight `#if DEBUG` "test probe" views that expose internal `ViewerState` properties as strings (e.g. `"currentstem=DSC04180"`). This lets tests read internal state cheaply without inferring from pixels.

## Step 1 — Git LFS setup

**Prerequisites** (one-time, documented in `bootstrap.sh` + README):
```sh
brew install git-lfs
git lfs install
```

**`.gitattributes`** (committed):
```
*.ARW filter=lfs diff=lfs merge=lfs -text
*.HIF filter=lfs diff=lfs merge=lfs -text
*.xmp filter=lfs diff=lfs merge=lfs -text
```

**Curate the 20-pair subset** from existing `sample/`:
- Pick a mix of landscape + portrait + close-up + wide for orientation/AF coverage.
- Copy to `fixtures/integration/` (new folder, NOT a rename of `sample/` which stays gitignored as the user's working folder).
- Verify each pair has a matching `.xmp` sidecar with a known rating/label state so tests have a deterministic starting condition. If not all do, generate them with `XMPSidecarWriter` ahead of commit.
- Document the chosen pairs in `fixtures/integration/MANIFEST.md` (just the list of stems + what each one is good for in tests, e.g. "DSC04183 = portrait orientation").

**`scripts/bootstrap.sh` additions**:
```sh
command -v git-lfs >/dev/null || { echo "[bootstrap] git-lfs missing (brew install git-lfs && git lfs install)"; exit 1; }
git lfs install --local >/dev/null
# Pull LFS pointers if any are missing (handles freshly-cloned repos)
if [[ -d fixtures/integration ]] && [[ -z "$(find fixtures/integration -name '*.ARW' -size +1c -print -quit)" ]]; then
  echo "[bootstrap] fetching LFS fixtures (~1.3 GB)…"
  git lfs pull
fi
```

## Step 2 — Production code changes (small, intrusive)

### 2a. Accessibility identifiers (~14 additions, no behaviour change)

Identifiers we'll add (path → identifier):

| File | View | identifier |
|---|---|---|
| `PhotoX/ContentView.swift` | toolbar Open button | `toolbar.open` |
| `PhotoX/ContentView.swift` | toolbar Filmstrip toggle | `toolbar.filmstrip` |
| `PhotoX/ContentView.swift` | toolbar Sidebar toggle | `toolbar.sidebar` |
| `PhotoX/StatusBarView.swift` | filter Toggle (rated) | `statusbar.filter.rated` |
| `PhotoX/StatusBarView.swift` | filter Toggle (rejected) | `statusbar.filter.rejected` |
| `PhotoX/StatusBarView.swift` | filter Toggle (unrated) | `statusbar.filter.unrated` |
| `PhotoX/StatusBarView.swift` | "<N> shown" text | `statusbar.shown` |
| `PhotoX/Sidebar/DecisionsPanelView.swift` | star Button (1...5) | `sidebar.rating.\(N)` |
| `PhotoX/Sidebar/DecisionsPanelView.swift` | Reject Button | `sidebar.reject` |
| `PhotoX/Sidebar/DecisionsPanelView.swift` | label dot Button (Red/Yellow/Green/Blue/Purple) | `sidebar.label.\(name)` |
| `PhotoX/Filmstrip/FilmstripView.swift` | thumbnail content shape (per pair) | `filmstrip.\(pair.stem)` |

Applied via `.accessibilityIdentifier("…")` on the Button/View. Zero behaviour change in production.

### 2b. Test probe view (DEBUG only)

A tiny invisible view that emits ViewerState into accessibility values so tests can read internal state without inferring from pixels. Lives in `PhotoX/Util/TestProbes.swift`:

```swift
#if DEBUG
import SwiftUI

/// Invisible (frame .zero, hidden) view that surfaces ViewerState properties as
/// accessibility values. XCUITests read these via .otherElements[id].value to
/// verify internal state without depending on visible text formatting.
///
/// Only compiled in DEBUG builds — Release builds carry zero overhead and have
/// no accessibility surface for these probes.
struct TestProbes: View {
    let state: ViewerState

    var body: some View {
        VStack(spacing: 0) {
            probe("testprobe.currentstem",      state.pair?.stem ?? "")
            probe("testprobe.currentindex",     "\(state.currentIndex)")
            probe("testprobe.shootcount",       "\(state.shoot?.count ?? 0)")
            probe("testprobe.shownCount",       "\(state.shownCount)")
            probe("testprobe.rating",           "\(state.currentXMP.rating.map(String.init) ?? "")")
            probe("testprobe.label",            state.currentXMP.label ?? "")
            probe("testprobe.displayedVariant", state.displayedVariant.rawValue)
            probe("testprobe.sidebarVisible",   "\(state.sidebarVisible)")
            probe("testprobe.filmstripVisible", "\(state.filmstripVisible)")
            probe("testprobe.error",            state.errorMessage ?? "")
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    @ViewBuilder
    private func probe(_ id: String, _ value: String) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityIdentifier(id)
            .accessibilityValue(value)
    }
}
#endif
```

In `ContentView.swift`, append `#if DEBUG; TestProbes(state: state); #endif` as an overlay or hidden sibling so it's part of the main window's accessibility tree.

## Step 3 — PhotoXUITests target

**`project.yml` addition**:
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
      TEST_TARGET_NAME: PhotoX
```

**Scheme update** (`project.yml` `schemes.PhotoX.test.targets`): add `PhotoXUITests` alongside `PhotoXTests`. `xcodebuild test` will then run both suites.

## Step 4 — Test helpers

**`PhotoXUITests/PhotoXUITestCase.swift`** — base class encapsulating fixture isolation:

```swift
import XCTest

class PhotoXUITestCase: XCTestCase {
    var app: XCUIApplication!
    var fixtureDir: URL!
    var fixtureSource: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Per-test temp copy of the LFS-managed fixtures so tests that mutate
        // XMP don't leave the working tree dirty. `git status --porcelain`
        // must stay clean after the suite runs.
        fixtureSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // PhotoXUITests/
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("fixtures/integration")
        fixtureDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photoxui-\(UUID().uuidString)")
        try? FileManager.default.copyItem(at: fixtureSource, to: fixtureDir)

        app = XCUIApplication()
        app.launchEnvironment["PHOTOX_SAMPLE_DIR"] = fixtureDir.path
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: fixtureDir)
        super.tearDown()
    }

    // MARK: probes — read DEBUG-only test probes

    func probe(_ id: String) -> String {
        app.otherElements[id].value as? String ?? ""
    }

    @discardableResult
    func waitForShootLoaded(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate { _, _ in
            (self.probe("testprobe.shootcount") as NSString).integerValue > 0
        }
        let expectation = expectation(for: predicate, evaluatedWith: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: input helpers

    func type(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    func type(_ character: String, modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(character, modifierFlags: modifiers)
    }
}
```

## Step 5 — The 12 test scenarios

All in `PhotoXUITests/`. Concise list — each test fits in 5–15 LOC of body using the helpers above.

| # | Test | Asserts |
|---|---|---|
| 1 | `SmokeTests.test_launch_loadsFirstPair` | `waitForShootLoaded()` returns true; `probe("currentindex") == "0"`; `probe("error") == ""` |
| 2 | `NavigationTests.test_rightArrow_advancesIndex` | Press →; `probe("currentindex") == "1"`. Press → ×3; `currentindex == "4"`. |
| 3 | `NavigationTests.test_optionArrow_skipsTen` | Press ⌥+→; `currentindex == "10"`. |
| 4 | `NavigationTests.test_homeEnd_jumpToBoundaries` | Press End; `currentindex == "19"`. Press Home; `currentindex == "0"`. |
| 5 | `NavigationTests.test_filmstripClick_selectsThumbnail` | Tap `filmstrip.\(stem20)`; `probe("currentstem")` equals that stem. |
| 6 | `RatingTests.test_keyboard3_setsRatingAndWritesXMP` | Press "3"; `probe("rating") == "3"`; on disk, `<stem>.xmp` contains `xmp:Rating>3`. |
| 7 | `RatingTests.test_shift2_setsYellowLabel` | Press Shift+2; `probe("label") == "Yellow"`. Read XMP; label="Yellow". |
| 8 | `RatingTests.test_R_togglesReject_andClears` | Press R; `probe("rating") == "-1"`. Press R again; `probe("rating") == ""`. |
| 9 | `FilterTests.test_hideRejected_shrinksShownCount` | Rate two pairs reject; tap `statusbar.filter.rejected` to turn off; `probe("shownCount")` decreased by 2; press → and verify it skips the rejected pairs. |
| 10 | `VariantTests.test_Z_swapsHEIFtoRAW` | `probe("displayedVariant") == "heif"`; press Z; poll until `displayedVariant == "raw"` (LibRaw decode may take ~1s); `probe("error") == ""`. |
| 11 | `VisibilityTests.test_B_togglesSidebar_T_togglesFilmstrip` | Press B; `probe("sidebarVisible") == "false"`. Press B; `"true"`. Same for T + `filmstripVisible`. |
| 12 | `AboutTests.test_aboutPanelShowsGitDescribe` | `app.menuItems["About PhotoX"].click()`; verify the "About" window contains text matching `^0\.\d+\.0` or `^v0\.`. Click Close. |

**Excluded** (not worth the flakiness): Settings persistence across launches (needs to terminate + relaunch in one test, which fights with XCTestCase lifecycle); thumbnail-image content checks (requires pixel inspection).

## Step 6 — Bootstrap + release script updates

**`scripts/bootstrap.sh`**:
- Add `git-lfs` to the prerequisite check.
- Add `git lfs install --local` (idempotent).
- Add a `git lfs pull` invocation gated on "are the fixture files still LFS pointers?" so a fresh clone gets the bytes.

**`scripts/release.sh --verify-only`**:
- Already runs `xcodebuild test -only-testing:PhotoXTests/BundledResourcesTests`. Change to run the full Debug test suite (`xcodebuild test` with no `-only-testing` filter) so both unit AND UI tests run before any release is cut.
- UI tests take ~30–60 s (each test spawns + tears down the app); acceptable for a release gate.
- Add a post-test guard: `git status --porcelain fixtures/integration | grep -q . && fail "UI tests dirtied fixture files"` to catch leakage.

## Step 7 — README updates

Append a "Running tests" section explaining `xcodebuild test`, the `git lfs pull` requirement, and the convention that UI tests must never leave `fixtures/integration/` modified.

## Critical files (read these to execute)

- `/Users/frostman/workspace/personal/photo-x/project.yml` — add PhotoXUITests target + scheme entry
- `/Users/frostman/workspace/personal/photo-x/PhotoX/ContentView.swift` — add `.accessibilityIdentifier` on 3 toolbar buttons + the `#if DEBUG TestProbes(state:)` overlay
- `/Users/frostman/workspace/personal/photo-x/PhotoX/StatusBarView.swift` — add 4 accessibility identifiers (3 filter toggles + the shown count)
- `/Users/frostman/workspace/personal/photo-x/PhotoX/Sidebar/DecisionsPanelView.swift` — add 11 identifiers (5 stars + reject + 5 labels)
- `/Users/frostman/workspace/personal/photo-x/PhotoX/Filmstrip/FilmstripView.swift` — add identifier on the per-pair thumbnail
- `/Users/frostman/workspace/personal/photo-x/PhotoX/Util/TestProbes.swift` — NEW (`#if DEBUG` only)
- `/Users/frostman/workspace/personal/photo-x/PhotoXUITests/PhotoXUITestCase.swift` — NEW base class
- `/Users/frostman/workspace/personal/photo-x/PhotoXUITests/*Tests.swift` — NEW (5 files: SmokeTests, NavigationTests, RatingTests, FilterTests, VariantTests, VisibilityTests, AboutTests)
- `/Users/frostman/workspace/personal/photo-x/.gitattributes` — NEW
- `/Users/frostman/workspace/personal/photo-x/fixtures/integration/` — NEW directory tracked via LFS
- `/Users/frostman/workspace/personal/photo-x/scripts/bootstrap.sh` — add git-lfs prerequisite + `git lfs pull`
- `/Users/frostman/workspace/personal/photo-x/scripts/release.sh` — `--verify-only` runs the full test suite, asserts `git status` stays clean

## Existing utilities to reuse

- `PHOTOX_SAMPLE_DIR` env var (in `PhotoX/Loading/SamplePathProvider.swift`) — already bypasses NSOpenPanel. No changes needed.
- `XMPSidecarReader.read(for:)` and `XMPSidecarWriter.updateRating/updateLabel` — used by tests to verify on-disk state after keyboard input.
- `ViewerState` — direct in-process state surface; we never touch it from tests except indirectly via probes.

## Verification

1. **Setup smoke**: `git lfs install && ./scripts/bootstrap.sh && xcodegen && xcodebuild test` — all 84 existing unit tests still pass, plus all 12 UI tests pass.
2. **Fixture immutability**: after the full `xcodebuild test` run, `git status --porcelain fixtures/integration/` is empty.
3. **Release gate**: `./scripts/release.sh --verify-only` runs both suites and exits 0 only if everything passes.
4. **Fresh-clone scenario**: in a clean clone, `./scripts/bootstrap.sh` pulls LFS fixtures, then `xcodebuild test` runs the full suite — same result.
5. **Visual sanity check**: run a single UI test like `RatingTests.test_keyboard3_setsRatingAndWritesXMP` — observe the app launch, see "3" press, verify the star is rendered yellow in the sidebar, then app terminates. Confirms the harness works visually.
6. **Failure modes**:
   - Delete an accessibility identifier from a button → UI test that uses it fails with a recognisable "element not found" message.
   - Break `XMPSidecarWriter` (e.g. comment out the `desc.addChild`) → RatingTests fails the on-disk XMP assertion.
   - Break filter logic → FilterTests fails the shownCount check.

## What this constrains for Phase 4+

- Adding new toolbar/sidebar buttons → add an accessibility identifier following the `area.role.detail` convention or UI tests will become flaky.
- Renaming `ViewerState` properties surfaced through TestProbes → update the probe + tests in lockstep.
- Adding LFS-managed binary fixtures grows the repo's LFS bandwidth budget. Trim aggressively; resist the urge to commit "just one more sample shoot".
- Headless / CI: the same `xcodebuild test` works on GitHub-hosted macOS runners (with `git lfs pull` in the workflow). Phase 4 can add `.github/workflows/test.yml` without restructuring.
- The `#if DEBUG` test probes mean Release builds carry no test surface — friends' apps stay clean.
