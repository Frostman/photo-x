#!/bin/bash
# Print the README screenshot checklist — what to capture and where to save.
# Capture them yourself with your preferred tool (Cmd+Shift+4 + Space picks
# a window on macOS) and drop the PNGs into docs/screenshots/.
#
# Re-run whenever the README's marketing surface changes; the checklist
# below is the source of truth for what's referenced in README.md.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

OUT_DIR="docs/screenshots"
mkdir -p "$OUT_DIR"

cat <<EOF
Drop captured PNGs into:  $OUT_DIR/

Expected files + setup:

  01-hero.png
    Load a landscape image with rich AF data and a visible burst
    nearby in the filmstrip. Sidebar VISIBLE (Decisions + EXIF +
    histogram). AF overlay ON (press A). Filmstrip VISIBLE with the
    burst-bracket overlay across the burst frames.

  02-starter.png
    Close the current shoot. Empty starter screen (recents /
    favorites / volume list) visible.

Tip: Cmd+Shift+4 then press Space, then click the PhotoX window to
capture just the window (no desktop bleed, no shadow if you hold ⌥).
EOF
