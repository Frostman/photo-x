# vm-e2e runner-attach hang — root-cause diagnosis (Phase 0)

Captured: 2026-06-03.

## Symptom

`just vm-e2e` (no filter, full suite) on a cold or long-suspended VM takes ~10 minutes wall, with a ~5 min 30 s "silent" gap between xcodebuild starting and the UI test runner printing `Running tests...`. On warm VMs the same invocation takes ~234 s — the gap shrinks to ~7 s but the underlying pathology is the same. Stability runs occasionally synthesize a `PhotoX (NNN) encountered an error — The test runner hung before establishing connection` row with `0.00s` duration; that is the same bug failing closed at the xcresult layer instead of recovering.

## Root cause

The patched xctestrun (`build/vm/dd/Build/Products/.patched-PhotoX_macosx26.5-arm64.xctestrun`) declares two test targets:

| Target | Run order | Host kind | Test host |
|---|---|---|---|
| `PhotoXTests` | 0 | app-hosted (`IsAppHostedTestBundle = true`) | `__TESTROOT__/Debug/PhotoX.app` |
| `PhotoXUITests` | 1 | xctrunner-hosted (`IsXCTRunnerHostedTestBundle = true`) | `__TESTROOT__/Debug/PhotoXUITests-Runner.app` |

`xcodebuild test-without-building` walks `RunOrder` ascending, so the unit-test target runs first. In the VM, it never actually runs — the unit-test host process launches, sits, then is abandoned. From the captured unified log on the 10-min repro:

```
18:18:07.689  PhotoX[929]  launching (unit-test host)
18:18:09.028  PhotoX[929]  last xpc/AppKit/LaunchServices activity
18:18:18.735  PhotoX[929]  LSExceptions shared instance invalidated for timeout
              … 5 min 27 s of complete silence from PID 929 …
18:23:45.769  PhotoXUITests-Runner[1005]  starts
18:23:46.265  PhotoX[1006]  fresh launch (UI-test host)
```

PID 929 is abandoned (it is *not* the same process that the UI runner later attaches to — PID 1006 is). The 327-second silence aligns closely with a 300-second xctest bundle-load timeout. The xcresult test-suite header confirms it never ran:

```
Test Suite 'All tests' started at 18:23:46
Test Suite 'PhotoXUITests.xctest' started at 18:23:46
```

No `PhotoXTests.xctest` suite is ever opened. Looking back at the stability log from earlier in the day, the same is true on warm runs — every "successful" 234s run only reports PhotoXUITests results; PhotoXTests never appears.

Therefore: **the unit-test target has never executed in the VM. xcodebuild times out trying, and only then proceeds to the UI tests.** The cost of that timeout dominates wall-clock on cold-suspend runs.

## Direct evidence (validation run)

Filtering to `PhotoXUITests` from a cold-suspend state collapses the gap and clears the known flakes:

| Run | Filter | Wall | Tests | Failures |
|---|---|---|---|---|
| cold-suspend, no filter | full suite | 10:05 | 31 | runner-hang + keyMonitor flake |
| cold-suspend, `PhotoXUITests` | UI bundle only | 4:51 | 30 | 0 |

The 314-second / ~52% improvement is the unit-test timeout disappearing.

## What the other "suspicious" signals turned out to be

- `DebuggerLLDB.DebuggerVersionStore.StoreError error 0` and `no debugger version` — emitted on every single test launch including fast ones (single-test SmokeTests warm and cold). Unrelated to the hang.
- `[MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty` — printed 3-4× on every invocation including fast ones. Also unrelated. The xctestrun has `FormatVersion: 1` with no `SupportedDestinations` array, but this only causes the warning, not the timeout.
- `[Invalid Configuration] NSHostingView is being laid out reentrantly` — emitted at every PhotoX startup including fast single-test runs. Unrelated to the hang (might still be worth fixing for SwiftUI correctness, but not on this critical path).

## Why unit tests fail to inject in the VM

Not investigated further in Phase 0 — irrelevant once we stop trying. Plausible candidates if it ever needs to be solved: the bundle's `DYLD_INSERT_LIBRARIES` path resolution against the VM's `__PLATFORMS__` placeholder; an entitlement gap on the test host inside the VM's TCC profile; the `PhotoXTests.xctest` plugin requiring a host-side codesign that doesn't survive rsync. Unit tests run in `just test` on the host, so the VM doesn't need to run them.

## Fix path (Phase 2)

Strip `PhotoXTests` from the patched xctestrun in `_patch_xctestrun_env` (`scripts/vm-remote.sh:463`) before shipping. The host-side `_find_xctestrun` keeps producing the original bundle; only the VM copy loses the unit-test target. Effects:

- Cold-suspend full-suite wall: 10:05 → ~5:00.
- Warm full-suite wall: 234s → ~227s.
- Smoke gate and `-only-testing:` filters: unchanged (they already skip PhotoXTests).
- `just test` on the host: unchanged (different invocation path).
- `--rerun-failed` and stability tooling: unchanged.

This is a simpler intervention than the branching fix matrix the original Phase 2 plan anticipated.
