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
    xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -destination "$DEST" -quiet build

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
