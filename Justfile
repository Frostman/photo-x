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

    # Mirror scripts/release.sh's version derivation so dev builds carry a
    # real, git-derived version (CFBundleShortVersionString, CFBundleVersion,
    # GIT_DESCRIBE). The -dev suffix makes the About box unambiguous: even a
    # clean-tree dev artifact reads "v0.X.0-<sha>-dev" so it can never be
    # mistaken for a release.
    echo "==> Derive version from git"
    COMMITS=$(git rev-list --count HEAD)
    SHA9=$(git rev-parse --short=9 HEAD)
    DIRTY=""
    [ -n "$(git status --porcelain)" ] && DIRTY="-dirty"
    MARKETING="0.${COMMITS}.0"
    BUILD="${COMMITS}"
    DESCRIBE="v${MARKETING}-${SHA9}${DIRTY}-dev"
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
        GIT_DESCRIBE="$DESCRIBE"

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

# Compile-check the Debug target. Use this while editing — it's the
# fast path that does NOT relaunch the dev app (unlike `just dev`).
# No clean, no version injection — just enough to surface type errors.
build:
    xcodebuild -scheme PhotoX -configuration Debug -destination 'platform=macOS' build

# Run the test suite (or a slice of it).
#   just test                                              → full suite
#   just test PhotoXTests/TIFFEXIFParserTests              → one class
#   just test PhotoXTests/TIFFEXIFParserTests/test_X       → one method
# Multiple `-only-testing:` filters by passing space-separated args.
test *only="":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS=(test -scheme PhotoX -configuration Debug -destination 'platform=macOS')
    for filter in {{only}}; do
        ARGS+=(-only-testing:"$filter")
    done
    # Hard 60s cap — unit tests should never need longer; a hang here
    # almost always means a stuck subprocess or runaway test, so we
    # fail fast instead of waiting indefinitely.
    timeout 60 xcodebuild "${ARGS[@]}"

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

# Cut a release via scripts/release.sh.
#   just release              → full release (build, sign, DMG, publish)
#   just release --verify-only → build + tests, no publish
#   just release --dry-run    → full build + DMG, no commit/push
release *args:
    ./scripts/release.sh {{args}}
