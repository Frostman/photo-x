# Default — `just` with no args triggers `dev`.
default: dev

# Cleanly rebuild the Debug app and relaunch it.
#
# Touches only the dev build — /Applications/PhotoX.app (Release,
# bundle id dev.frostman.PhotoX) is left alone. The dev build has a
# separate bundle id (dev.frostman.PhotoX.debug), so Launch Services
# treats it as a distinct app; pkill matches the dev binary by full
# path, and we launch by full path so LS can't route to the wrong app.
dev:
    #!/usr/bin/env bash
    set -euo pipefail

    SCHEME=PhotoX
    CONFIG=Debug
    DEST='platform=macOS'

    echo "==> Regenerate .xcodeproj from project.yml"
    xcodegen

    # Dev builds advertise CFBundleShortVersionString=0.0.0 (and
    # CFBundleVersion=0) so Sparkle always sees every prod-appcast
    # item as "newer" — the upgrade pill surfaces within ~10 s of
    # every `just dev` rebuild, which is the primary workflow for
    # exercising the self-update popup against real Sparkle without
    # cutting a release. GitDescribe stays git-derived so the About
    # panel still reads like a real dev build.
    SHA9=$(git rev-parse --short=9 HEAD)
    # Dirty trees get a `-dirty-HHMMSS` suffix (local time) so
    # back-to-back `just dev` rebuilds without a commit still produce
    # a distinguishable About-panel string and a different Info.plist
    # GitDescribe. Mirrors scripts/vm-remote.sh's expected_git_describe
    # so a vm-e2e run started immediately after a `just dev` of the
    # same tree produces a visibly-related (but not identical) stamp.
    DIRTY=""
    [ -n "$(git status --porcelain)" ] && DIRTY="-dirty-$(date +%H%M%S)"
    MARKETING="0.0.0"
    BUILD="0"
    DESCRIBE="v0.0.0-dev-${SHA9}${DIRTY}"
    echo "    $DESCRIBE"

    echo "==> Resolve Debug build path"
    BUILD_DIR="$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -destination "$DEST" \
        -showBuildSettings 2>/dev/null \
        | awk '/^[[:space:]]*BUILT_PRODUCTS_DIR = /{print $3; exit}')"
    APP_PATH="$BUILD_DIR/$SCHEME.app"
    EXE_PATH="$APP_PATH/Contents/MacOS/$SCHEME"
    echo "    $APP_PATH"

    # Remember the previous binary's mtime so we can prove the rebuild
    # actually wrote a new artifact (catches a silent xcodebuild that
    # produced nothing fresh — e.g. cached, wrong scheme).
    OLD_MTIME=""
    if [ -f "$EXE_PATH" ]; then
        OLD_MTIME="$(stat -f %m "$EXE_PATH")"
    fi

    echo "==> Quit any running dev build (Release app untouched)"
    # IMPORTANT: kill ONLY the main app binary, not the
    # PhotoXCardWatcher helper that lives next to it. `pkill -f
    # "$EXE_PATH"` would substring-match both (the helper's path
    # has $EXE_PATH as a prefix), which kills the launchd-managed
    # helper while the bundle is being torn down for rebuild and
    # leaves it un-respawned. Match the first command word
    # ($2 in `ps -o command`) exactly against $EXE_PATH instead.
    PIDS=$(ps -ax -o pid,command 2>/dev/null \
            | awk -v target="$EXE_PATH" '$2 == target { print $1 }') || true
    [ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
    # The card-watcher helper itself is bounced by
    # PhotoXApp.bootstrap on every launch, so it picks up any
    # fresh binary even though `just dev` no longer kills it.

    echo "==> Clean previous Debug products"
    xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -destination "$DEST" -quiet clean
    rm -rf "$APP_PATH"

    echo "==> Build Debug"
    xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -destination "$DEST" -quiet build \
        MARKETING_VERSION="$MARKETING" \
        CURRENT_PROJECT_VERSION="$BUILD" \
        GIT_DESCRIBE="$DESCRIBE" \
        POSTHOG_API_KEY="$(just _posthog_key)"

    if [ ! -x "$EXE_PATH" ]; then
        echo "Error: build did not produce $EXE_PATH" >&2
        exit 1
    fi
    NEW_MTIME="$(stat -f %m "$EXE_PATH")"
    if [ -n "$OLD_MTIME" ] && [ "$NEW_MTIME" = "$OLD_MTIME" ]; then
        echo "Error: binary mtime unchanged ($OLD_MTIME) — build did not write a fresh artifact" >&2
        exit 1
    fi
    echo "    fresh binary (mtime $NEW_MTIME, was ${OLD_MTIME:-<none>})"

    # Xcode produces an intermediate copy of the helper at
    # $BUILT_PRODUCTS_DIR/PhotoXCardWatcher.app alongside
    # PhotoX.app, then embeds the same bundle inside
    # PhotoX.app/Contents/Library/LoginItems/. Both .apps
    # have the same CFBundleIdentifier
    # (`dev.frostman.PhotoX.debug.CardWatcher`) but the
    # sibling is the one LaunchServices indexes first
    # (since it's directly inside BUILT_PRODUCTS_DIR that
    # LS auto-scans), which routes notification-click
    # activations + icon lookups to the WRONG path. Remove
    # the sibling and unregister it from LS so the nested
    # copy becomes the canonical bundle.
    SIBLING_HELPER="$BUILD_DIR/PhotoXCardWatcher.app"
    LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
    if [ -d "$SIBLING_HELPER" ]; then
        echo "==> Remove sibling $SIBLING_HELPER (LS-confusion preventer)"
        "$LSREG" -u "$SIBLING_HELPER" 2>/dev/null || true
        rm -rf "$SIBLING_HELPER"
    fi

    echo "==> Launch dev build"
    open -a "$APP_PATH"

# Bootstrap vendored deps (LibRaw + exiftool) and regenerate the
# Xcode project. Idempotent; safe to re-run after pulling.
#   just bootstrap            → materialise missing deps
#   just bootstrap --force    → re-download even if already present
# just bootstrap --verify   → check only, don't write
bootstrap *args:
    ./scripts/bootstrap.sh {{ args }}

# Print the PostHog ingest key, sourced from $POSTHOG_API_KEY (env)
# or scripts/release.local.env (gitignored). Empty string when
# neither is set — TelemetryUploader treats empty as a no-op, so
# missing-key dev builds run fine without uploading anything.
# Used by `just build` / `just dev` to inject the key as an
# xcodebuild override; release.sh sources release.local.env
# directly and forwards the same setting.
_posthog_key:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "${POSTHOG_API_KEY:-}" ]; then
        printf '%s' "$POSTHOG_API_KEY"
    elif [ -f scripts/release.local.env ]; then
        grep -E '^POSTHOG_API_KEY=' scripts/release.local.env \
          | head -1 | cut -d= -f2- | tr -d '"' || true
    fi

# Compile-check the Debug target. Use this while editing — it's the
# fast path that does NOT relaunch the dev app (unlike `just dev`).
# No clean, no version injection — just enough to surface type errors.
#
# CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES disables Xcode's
# tripwire that fails the build when an entitlements file's
# size/mtime appears to change mid-build. The check is fine in a
# normal host workflow but trips inside the VM-backed e2e path
# (vm-build / vm-e2e) because the source is rewritten by a tar
# stream before each build, and Xcode 26.5 flags that as
# modification even when the content is byte-identical to the
# previous extraction. We're not shipping signed binaries from
# Debug builds, so disabling the tripwire is harmless — the
# entitlements content itself is unchanged.
build:
    xcodebuild -scheme PhotoX -configuration Debug -destination 'platform=macOS' build \
        POSTHOG_API_KEY="$(just _posthog_key)" \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES

# Run the test suite (or a slice of it).
#   just test                                              → full suite
#   just test PhotoXTests/TIFFEXIFParserTests              → one class
#   just test PhotoXTests/TIFFEXIFParserTests/test_X       → one method
# Multiple `-only-testing:` filters by passing space-separated args.
test *only="":
    #!/usr/bin/env bash
    set -euo pipefail
    # -only-testing:PhotoXTests pins this to the unit suite — the
    # scheme also has PhotoXUITests under it, but those are slow and
    # go through `just e2e` instead.
    ARGS=(test -scheme PhotoX -configuration Debug -destination 'platform=macOS' -only-testing:PhotoXTests)
    for filter in {{ only }}; do
        ARGS+=(-only-testing:"$filter")
    done
    # CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES: see comment on
    # the `build` recipe — needed for vm-test where tar-stream sync
    # perturbs source mtimes.
    ARGS+=(CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES)
    # Hard 60s cap — unit tests should never need longer; a hang here
    # almost always means a stuck subprocess or runaway test, so we
    # fail fast instead of waiting indefinitely.
    timeout 60 xcodebuild "${ARGS[@]}"

# Run the E2E (XCUITest) suite. Slower than `just test` because each
# test launches the real app and clones the full sample/ fixture into
# a temp dir. 10-min hard cap (anything longer is almost certainly a
# hang — e.g. a permission dialog popped or the app deadlocked).
#
# `PhotoXUITests/` prefix is auto-added when missing. Multiple
# filters form a union, so you can run several classes/methods in
# one invocation.
#   just e2e                                          → full UI suite
#   just e2e SmokeTests                               → one class (shorthand)
#   just e2e PhotoXUITests/SmokeTests                 → one class (explicit)
#   just e2e RatingTests/test_starRating_writesXMPSidecar → one method
#   just e2e RatingTests UndoTests                    → two classes
e2e *only="":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS=(test -scheme PhotoX -configuration Debug -destination 'platform=macOS')
    # Collect user filters first; -only-testing is additive in
    # xcodebuild, so emitting the bundle-wide PhotoXUITests filter
    # alongside narrow ones (RatingTests, UndoTests, …) would force
    # the union back up to the whole bundle. Apply the bundle-wide
    # filter only when no user filters are passed — that keeps unit
    # tests out of the e2e recipe (they live in PhotoXTests/ and run
    # via `just test`).
    FILTERS=()
    for filter in {{ only }}; do
        case "$filter" in
            PhotoXUITests/*|PhotoXUITests) FILTERS+=("$filter") ;;
            *)                             FILTERS+=("PhotoXUITests/$filter") ;;
        esac
    done
    if [[ ${#FILTERS[@]} -eq 0 ]]; then
        ARGS+=(-only-testing:PhotoXUITests)
    else
        for f in "${FILTERS[@]}"; do ARGS+=(-only-testing:"$f"); done
    fi
    # CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES: see comment on
    # the `build` recipe — needed for vm-e2e where tar-stream sync
    # perturbs source mtimes.
    ARGS+=(CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES)
    timeout 600 xcodebuild "${ARGS[@]}"

# Regenerate the Release + Debug app iconsets via the icon generator.
# Writes PNGs into PhotoX/Assets.xcassets/{AppIcon,AppIcon-Debug}.appiconset/.
# Re-run only when the icon design or the generator script changes.
icon:
    swift scripts/generate_icon.swift

# Print the README screenshot checklist (what to capture + where to save).
# Capture them yourself with Cmd+Shift+4 + Space and drop the PNGs into
# docs/screenshots/.
screenshots:
    ./scripts/screenshots.sh

# Print the release version that would be produced from the current
# tree — same derivation as scripts/release.sh:
#   v0.<commit-count>.0-<sha9>[-dirty]
# Useful as a dry-run before `just release` to confirm what tag /
# MARKETING_VERSION / CURRENT_PROJECT_VERSION will land.
version:
    #!/usr/bin/env bash
    set -euo pipefail
    COMMITS=$(git rev-list --count HEAD)
    SHA9=$(git rev-parse --short=9 HEAD)
    DIRTY=""
    [ -n "$(git status --porcelain)" ] && DIRTY="-dirty"
    MARKETING="0.${COMMITS}.0"
    BUILD="${COMMITS}"
    DESCRIBE="v${MARKETING}-${SHA9}${DIRTY}"
    TAG="v${MARKETING}"
    echo "describe:  $DESCRIBE"
    echo "tag:       $TAG"
    echo "marketing: $MARKETING"
    echo "build:     $BUILD"

# Dump every EXIF / Sony / Composite tag PhotoX reads for a
# single photo, plus the .xmp sidecar if one exists alongside.
# Mirrors what the basic-EXIF + advanced-EXIF pipelines pull
# (TIFFEXIFParser fields + MetadataBatchLoader.tagArgs) — handy
# when comparing what PhotoX sees against what the camera
# actually wrote, or when a field is missing from the sidebar
# and you want to know whether the file has it.
#
# Usage: just inspect /path/to/photo.HIF
inspect file:
    #!/usr/bin/env bash
    set -euo pipefail
    EXIFTOOL=Resources/exiftool/exiftool
    if [ ! -x "$EXIFTOOL" ]; then
        echo "error: $EXIFTOOL not present — run scripts/bootstrap.sh first" >&2
        exit 1
    fi
    if [ ! -f "{{ file }}" ]; then
        echo "error: {{ file }} not found" >&2
        exit 1
    fi
    "$EXIFTOOL" -G1 -a -s \
        -EXIF:Make -EXIF:Model -EXIF:LensModel \
        -EXIF:ExposureTime -EXIF:FNumber -EXIF:ISO \
        -EXIF:FocalLength -EXIF:ExposureCompensation \
        -EXIF:DateTimeOriginal -EXIF:Orientation# \
        -EXIF:ExifImageWidth -EXIF:ExifImageHeight \
        -Sony:SequenceNumber -Sony:CameraOrientation# \
        -Sony:FocusMode -Sony:AFAreaMode -Sony:AFAreaModeSetting -Sony:AFTracking \
        -Sony:FocusLocation -Sony:FocusFrameSize \
        -Sony:FocalPlaneAFPointArea \
        -Sony:FocalPlaneAFPointLocation1 -Sony:FocalPlaneAFPointLocation2 \
        -Sony:FocalPlaneAFPointLocation3 -Sony:FocalPlaneAFPointLocation4 \
        -Sony:FocalPlaneAFPointLocation5 -Sony:FocalPlaneAFPointLocation6 \
        -Sony:FocalPlaneAFPointLocation7 -Sony:FocalPlaneAFPointLocation8 \
        -Sony:FocalPlaneAFPointLocation9 \
        -Sony:FocalPlaneAFPointsUsed \
        -Sony:Face1Position -Sony:Face2Position -Sony:Face3Position \
        -Sony:Face4Position -Sony:Face5Position -Sony:Face6Position \
        -Sony:FacesDetected \
        -Composite:FocusDistance -Composite:FocusDistance2 \
        "{{ file }}"
    # Stem-matched XMP sidecar (Lightroom-compatible naming).
    STEM_DIR="$(dirname "{{ file }}")"
    STEM="$(basename "{{ file }}")"
    STEM="${STEM%.*}"
    XMP="$STEM_DIR/$STEM.xmp"
    if [ -f "$XMP" ]; then
        echo
        echo "── XMP sidecar: $XMP ─────────────────────────"
        cat "$XMP"
    else
        echo
        echo "(no XMP sidecar at $XMP)"
    fi

# Cut a release via scripts/release.sh.
#   just release              → full release (build, sign, DMG, publish)
#   just release --verify-only → build + tests, no publish
# just release --dry-run    → full build + DMG, no commit/push
release *args:
    ./scripts/release.sh {{ args }}

# Toggle a fake camera-card mount for testing the background
# card watcher / Open tab's Cards section. Creates
# /tmp/photox-fake.dmg on first run from sample/ wrapped in
# DCIM/100PHOTOX/ + DCIM/101PHOTOX/ (the watcher only fires
# on volumes with DCIM/ at the root; the two shoot folders
# exercise the Cards section's multi-shoot rendering plus the
# helper's "pick the first 100XXXXX folder" logic). Subsequent
# runs toggle attach / detach. Volume mounts at /Volumes/PHOTOXFAKE.
fake-card:
    #!/usr/bin/env bash
    set -euo pipefail
    DMG=/tmp/photox-fake.dmg
    VOLUME=PHOTOXFAKE
    MOUNT="/Volumes/$VOLUME"

    if [ ! -f "$DMG" ]; then
        echo "==> Creating $DMG from sample/ split across DCIM/100PHOTOX + DCIM/101PHOTOX"
        if [ ! -d sample ]; then
            echo "error: sample/ not found — run from repo root" >&2
            exit 1
        fi
        # Stage sample/ under DCIM/ so the volume matches what
        # the watcher (and PhotoX's VolumeScanner) keys on.
        # mktemp dir is cleaned up on exit regardless of success.
        STAGE=$(mktemp -d)
        trap 'rm -rf "$STAGE"' EXIT
        mkdir -p "$STAGE/DCIM/100PHOTOX" "$STAGE/DCIM/101PHOTOX"
        # Split sample by stem (DSC00060, DSC04176, …) so each
        # subfolder keeps full ARW + JPG/HIF + xmp groups
        # together — splitting by file would scatter
        # raw/preview siblings across folders and confuse
        # ShootScanner's pair detection.
        STEMS=()
        while IFS= read -r stem; do STEMS+=("$stem"); done < <(ls sample | sed 's/\.[^.]*$//' | sort -u)
        HALF=$(( ${#STEMS[@]} / 2 ))
        for stem in "${STEMS[@]:0:$HALF}"; do
            cp sample/"$stem".* "$STAGE/DCIM/100PHOTOX/" 2>/dev/null || true
        done
        for stem in "${STEMS[@]:$HALF}"; do
            cp sample/"$stem".* "$STAGE/DCIM/101PHOTOX/" 2>/dev/null || true
        done
        # -ov overwrites if /tmp/photox-fake.dmg somehow exists
        # from a leftover state; -srcfolder builds the image
        # contents from STAGE.
        # -format UDRW is uncompressed read/write — orders of
        # magnitude faster to create than the default UDZO
        # (which compresses the entire ~3.7 GB sample), at the
        # cost of a fatter DMG on disk. We never ship this
        # image, so disk usage doesn't matter.
        hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -format UDRW -ov "$DMG" >/dev/null
        echo "    $DMG ready"
    fi

    if [ -d "$MOUNT" ]; then
        echo "==> Detaching $MOUNT"
        hdiutil detach "$MOUNT"
    else
        echo "==> Attaching $DMG → $MOUNT"
        hdiutil attach "$DMG" >/dev/null
        echo "    mounted at $MOUNT (DCIM/100PHOTOX inside)"
    fi

# ─── VM-backed e2e ──────────────────────────────────────────────────────────
#
# The `vm-*` family runs XCUITest end-to-end tests inside a Tart-
# managed macOS VM (`ghcr.io/cirruslabs/macos-tahoe-xcode:latest`)
# rather than on the host. The VM has its own WindowServer, so the
# host's cursor / focus / windows are never touched during a run —
# Claude Code (and the user) can iterate on e2e tests while still
# using this laptop for other work.
#
# Trade-offs to know about:
#   • CPU/RAM are shared with the host. A run consumes ~4 cores +
#     ~8 GB RAM while xcodebuild executes. Heavy host workloads
#     (video render, big Xcode build) will compete.
#   • Disk: ~80 GB sparse VM image (ghcr.io image) + ~3.7 GB sample/
#     duplicate (APFS clonefile doesn't cross the VM boundary, so the
#     fixture is rsynced into the VM once and lives there).
#   • The image follows :latest. When upstream pushes a new Xcode
#     image, `vm-e2e` detects the digest change and recreates the VM
#     (~3–5 min one-time catch-up).
#   • Credentials inside the VM are `admin/admin` (Cirrus image
#     default) — VM-internal-only.
#
# Architecture in one diagram:
#
#   host                                 VM (photox-e2e)
#   ────                                 ───────────────
#   just vm-e2e SmokeTests               admin user, GUI session
#      │                                 tart-guest-agent loaded
#      ├─ tart pull :latest (cheap)
#      ├─ recreate VM if image digest    /Volumes/My Shared Files/
#      │  changed since last clone         photox-src/ ←┐ virtiofs ro
#      ├─ tart run --no-graphics &                       │
#      ├─ tart exec rsync src ──────────┐                │
#      ├─ tart exec rsync sample/ once  │   ~/photo-x ←──┘  (writable)
#      ├─ tart exec just e2e <filter>   └─→ xcodebuild test
#      └─ pull xcresult on failure          → build/e2e-results/
#
# Failure modes are surfaced as `ERROR: <tag>` lines from
# scripts/vm-remote.sh — see that file for the tag → hint map.
# Use `just vm-shell` to drop into the VM for debugging.

# Run the XCUITest e2e suite (or a slice of it) inside the Tart VM.
# Idempotent: pulls image, creates/starts/provisions VM, syncs source,
# runs xcodebuild test-without-building, streams output back. First
# invocation is slow (~5–10 min cold pull + provision); subsequent
# runs are sync + xcodebuild only.
#
#   just vm-e2e                                             → full UI suite
#   just vm-e2e SmokeTests                                  → one class (shorthand)
#   just vm-e2e PhotoXUITests/SmokeTests                    → one class (explicit)
#   just vm-e2e RatingTests/test_starRating_writesXMPSidecar → one method
#   just vm-e2e RatingTests UndoTests                       → two classes
#
# `PhotoXUITests/` prefix is auto-added when missing. Multiple filters
# form a union (xcodebuild's -only-testing is additive). Filter syntax
# matches `just e2e` exactly. On failure, the latest .xcresult bundle
# is pulled to build/e2e-results/<timestamp>/ for inspection; the
# most-recent 5 are kept.
#
# Flags (passed through to scripts/vm-remote.sh):
#   --rerun-failed   replay only the tests that failed last run
#   --keep-on-fail   leave the VM running on failure for vm-shell/vm-screen
#   --record         keep the automatic screen recording for EVERY test
#                    (not just failures). Useful for reviewing what each
#                    test is doing. Bumps xcresult size by ~MBs per test.
#   --cold-boot      stop the VM first so this run cold-boots instead of
#                    resuming from suspend. Diagnostic escape hatch when
#                    you suspect the suspended state is corrupt.
#
#   just vm-e2e --record SmokeTests        → record video of one test
#   just vm-e2e --keep-on-fail RatingTests → debug a failing test in the VM
#   just vm-e2e --cold-boot                → fresh VM start for this run
vm-e2e *only="":
    ./scripts/vm-remote.sh run {{ only }}

# Run the unit suite inside the Tart VM. Same lifecycle as vm-e2e —
# the VM has its own WindowServer, so unlike `just test` it doesn't
# launch PhotoX.app on the host as the test host and interrupt your
# dev session. Warm boot resumes ~7 s, then sync + build + test.
#
#   just vm-test                                              → full unit suite
#   just vm-test TIFFEXIFParserTests                          → one class (shorthand)
#   just vm-test PhotoXTests/TIFFEXIFParserTests              → one class (explicit)
#   just vm-test PhotoXTests/TIFFEXIFParserTests/test_X       → one method
#   just vm-test ExportRunnerStateTests OverwriteDecisionTests → two classes
#
# `PhotoXTests/` prefix is auto-added when missing. Multiple filters
# form a union (xcodebuild's -only-testing is additive). Filter syntax
# matches `just test` exactly. On failure, the latest .xcresult bundle
# is pulled to build/test-results-vm/<timestamp>/ for inspection; the
# most-recent 5 are kept.
#
# Flags (passed through to scripts/vm-remote.sh):
#   --rerun-failed   replay only the tests that failed last run
#   --keep-on-fail   leave the VM running on failure for vm-shell
#   --cold-boot      stop the VM first so this run cold-boots instead of
#                    resuming from suspend. Diagnostic escape hatch when
#                    you suspect the suspended state is corrupt.
#
# --record is intentionally omitted — unit tests don't drive the
# screen, so a recording is just a static capture.
vm-test *only="":
    ./scripts/vm-remote.sh run-unit {{ only }}

# Run the suite N times to build a flake matrix. Always proceeds
# even when an iteration fails — the point is to measure failure
# rates. After the loop, `scripts/vm-stability-report.sh` walks the
# xcresults produced during the session and writes a markdown table
# to build/vm/stability/report.md. p50/p95 are computed over passing
# durations; rows whose every failure had duration 0 are flagged as
# `⚠ runner-hang` (the synthetic xcresult row that means the test
# runner couldn't attach to the host app).
#
#   just vm-e2e-stability             → 5 runs, full suite (default)
#   just vm-e2e-stability 20          → 20 runs, full suite
#   just vm-e2e-stability 10 RatingTests → 10 runs of one class
vm-e2e-stability N="5" *only="":
    #!/usr/bin/env bash
    set -euo pipefail
    N={{N}}
    SESSION_TS=$(date +%Y%m%dT%H%M%S)
    OUT=build/vm/stability
    SESSION_DIR="${OUT}/${SESSION_TS}"
    mkdir -p "${SESSION_DIR}"
    SESS_LOG="${OUT}/session-${SESSION_TS}.log"
    printf '=== stability session %s · N=%d · filter=%s ===\n' \
        "${SESSION_TS}" "${N}" "{{ only }}" | tee -a "${SESS_LOG}"
    just vm-up 2>&1 | tee -a "${SESS_LOG}"
    for i in $(seq 1 "${N}"); do
        printf '\n=== run %d/%d started at %s ===\n' \
            "${i}" "${N}" "$(date +%FT%T%z)" | tee -a "${SESS_LOG}"
        # Capture the `latest` target BEFORE the iteration so the
        # post-iteration snapshot can detect whether this iteration
        # actually produced a new xcresult or just left the symlink
        # pointing at the previous run (the VM-layer failure case —
        # we'd otherwise double-count the previous result). Also
        # snapshot build/vm/run.log's line count so the per-iteration
        # tart-side run-log slice (B5) is bounded to lines this
        # iteration appended — see post-iteration capture below.
        PRE_LATEST=$(readlink build/e2e-results/latest 2>/dev/null || true)
        PRE_RUNLOG_LINES=$(wc -l < build/vm/run.log 2>/dev/null | tr -d ' ' || echo 0)
        # `|| true` so one failed iteration doesn't abort the matrix.
        ./scripts/vm-remote.sh run {{ only }} 2>&1 | tee -a "${SESS_LOG}" || true
        POST_LATEST=$(readlink build/e2e-results/latest 2>/dev/null || true)
        POST_RUNLOG_LINES=$(wc -l < build/vm/run.log 2>/dev/null | tr -d ' ' || echo 0)
        RUN_LABEL=$(printf 'run-%02d' "${i}")
        # Always materialise the run-NN/ dir so the per-iteration
        # forensic surface is consistent: it holds at minimum a
        # tart-side run.log slice + (when produced) the xcresult.
        # VM-layer failures (no xcresult) thus still leave the
        # run.log behind for inspection.
        mkdir -p "${SESSION_DIR}/${RUN_LABEL}"
        # Tart-side run.log delta: snapshot-restore lines, VZ errors
        # (Code=2 / Code=12), guest-agent boot messages. Only useful
        # when something went wrong at the VM layer, but free to
        # capture and pairs with the xcresult for full forensics.
        NEW_RUNLOG_LINES=$((POST_RUNLOG_LINES - PRE_RUNLOG_LINES))
        if (( NEW_RUNLOG_LINES > 0 )); then
            tail -n "${NEW_RUNLOG_LINES}" build/vm/run.log \
                > "${SESSION_DIR}/${RUN_LABEL}/tart-run.log" 2>/dev/null || true
        fi
        if [[ -n "${POST_LATEST}" && "${POST_LATEST}" != "${PRE_LATEST}" ]]; then
            # Copy LATEST's contents into the already-created run-NN/
            # dir (trailing `/.` so cp puts files directly there
            # instead of nesting a `latest/` subdir). The xcresult
            # report script walks `find -name last.xcresult` and
            # finds it at any depth.
            cp -RH build/e2e-results/latest/. "${SESSION_DIR}/${RUN_LABEL}/" 2>/dev/null \
                || printf '  (xcresult snapshot failed for %s)\n' "${RUN_LABEL}" \
                    | tee -a "${SESS_LOG}"
        else
            printf '  (no new xcresult for %s — VM-layer failure or pre-test abort; tart-run.log is the only forensic artifact)\n' \
                "${RUN_LABEL}" | tee -a "${SESS_LOG}"
        fi
    done
    printf '\n=== report ===\n' | tee -a "${SESS_LOG}"
    ./scripts/vm-stability-report.sh "${SESSION_DIR}" | tee "${OUT}/report.md"

# Bring the VM up without running anything: pull image (if needed),
# clone (if needed), start, provision, sync. Useful at the start of a
# working session to absorb the ~30–45 s cold-start cost up-front so
# subsequent `vm-e2e` invocations are warm.
vm-up:
    ./scripts/vm-remote.sh up

# Stop the VM (saves ~8 GB RAM). Image and disk stay; `vm-up`
# resurrects the same VM with all provisioning intact. Run at end of
# day or before suspending the laptop.
vm-down:
    ./scripts/vm-remote.sh down

# SSH into the running VM for interactive debugging. Password is
# `admin` (Cirrus image default; VM-internal-only). Use to inspect
# failed builds, check `xcrun` versions, tail logs, etc.
vm-shell:
    ./scripts/vm-remote.sh shell

# Open macOS Screen Sharing on the VM's VNC URL. The VM boots with
# --vnc-experimental (see scripts/vm-remote.sh::_tart_run_suspendable)
# so VNC is always available without restart. Pairs nicely with
# `vm-e2e --keep-on-fail` for inspecting the in-VM state right after
# a test failure.
vm-screen:
    ./scripts/vm-remote.sh screen

# Open the latest e2e xcresult bundle in Xcode for interactive
# failure inspection (test activities, attachments, video, etc.).
# Faster than navigating to build/e2e-results/latest/ in Finder.
vm-open-results:
    open build/e2e-results/latest/last.xcresult

# Wipe test artifacts (~admin/test-artifacts) and DerivedData inside
# the VM. Forces the next `vm-e2e` to fully re-ship and re-link.
# Preserves sample/ — that's the slow-to-resync ~3.7 GB fixture.
vm-clean:
    ./scripts/vm-remote.sh clean

# Force-pull the latest upstream image and recreate the VM. Useful
# when the auto-update path (digest cache in `vm-e2e`) is suspected
# stale, or when you explicitly want today's image now. ~80 GB
# delete + re-occupy, ~30 s re-provision (the new lightweight
# provisioner). Normal `vm-e2e` already auto-pulls when upstream
# changes, so this is rarely needed.
vm-pull:
    ./scripts/vm-remote.sh pull

# One-line status snapshot: VM state (running / suspended / stopped),
# on-disk size of the VM directory (includes suspend snapshot), and
# the outcome of the last vm-e2e run.
vm-status:
    ./scripts/vm-remote.sh status
