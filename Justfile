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
    DIRTY=""
    [ -n "$(git status --porcelain)" ] && DIRTY="-dirty"
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
    pkill -f "$EXE_PATH" 2>/dev/null || true

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

    echo "==> Launch dev build"
    open -a "$APP_PATH"

# Bootstrap vendored deps (LibRaw + exiftool) and regenerate the
# Xcode project. Idempotent; safe to re-run after pulling.
#   just bootstrap            → materialise missing deps
#   just bootstrap --force    → re-download even if already present
#   just bootstrap --verify   → check only, don't write
bootstrap *args:
    ./scripts/bootstrap.sh {{args}}

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
build:
    xcodebuild -scheme PhotoX -configuration Debug -destination 'platform=macOS' build \
        POSTHOG_API_KEY="$(just _posthog_key)"

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
    for filter in {{only}}; do
        ARGS+=(-only-testing:"$filter")
    done
    # Hard 60s cap — unit tests should never need longer; a hang here
    # almost always means a stuck subprocess or runaway test, so we
    # fail fast instead of waiting indefinitely.
    timeout 60 xcodebuild "${ARGS[@]}"

# Run the E2E (XCUITest) suite. Slower than `just test` because each
# test launches the real app and clones the full sample/ fixture into
# a temp dir. 10-min hard cap (anything longer is almost certainly a
# hang — e.g. a permission dialog popped or the app deadlocked).
#   just e2e                                            → full suite
#   just e2e PhotoXUITests/SmokeTests                   → one class
#   just e2e PhotoXUITests/RatingTests/test_starRating_writesXMPSidecar → one method
e2e *only="":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS=(test -scheme PhotoX -configuration Debug -destination 'platform=macOS' -only-testing:PhotoXUITests)
    for filter in {{only}}; do
        ARGS+=(-only-testing:"$filter")
    done
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
    if [ ! -f "{{file}}" ]; then
        echo "error: {{file}} not found" >&2
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
        "{{file}}"
    # Stem-matched XMP sidecar (Lightroom-compatible naming).
    STEM_DIR="$(dirname "{{file}}")"
    STEM="$(basename "{{file}}")"
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
#   just release --dry-run    → full build + DMG, no commit/push
release *args:
    ./scripts/release.sh {{args}}
