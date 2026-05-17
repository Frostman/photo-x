#!/bin/bash
# Cuts a release of PhotoX. Version is derived entirely from git — never
# hand-bumped. Builds, performs static self-containment checks, ad-hoc
# codesigns, packages a DMG, signs it with Sparkle's EdDSA key, splices an
# entry into docs/appcast.xml, commits + pushes, and creates a GitHub Release
# via `gh`. Hermetic to this repo — no sudo, no writes outside the repo.
#
# Flags:
#   --verify-only   build + static checks + tests; no signing, DMG, or publish
#   --dry-run       full build + DMG + appcast snippet, but no commit/push/gh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

VERIFY_ONLY=0
DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --verify-only) VERIFY_ONLY=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    *) echo "usage: $0 [--verify-only|--dry-run]" >&2; exit 2 ;;
  esac
done

# Prerequisites
command -v xcodebuild >/dev/null || { echo "[release] xcodebuild missing"  >&2; exit 1; }
command -v hdiutil    >/dev/null || { echo "[release] hdiutil missing"     >&2; exit 1; }
command -v otool      >/dev/null || { echo "[release] otool missing"       >&2; exit 1; }
if [[ $DRY_RUN -eq 0 && $VERIFY_ONLY -eq 0 ]]; then
  command -v gh >/dev/null || { echo "[release] gh not installed (brew install gh)" >&2; exit 1; }
fi

# Vendored deps must be present (run bootstrap.sh first).
test -f ThirdParty/libraw/lib/libraw_r.a \
  || { echo "[release] ThirdParty/libraw missing — run scripts/bootstrap.sh" >&2; exit 1; }
test -x Resources/exiftool/exiftool \
  || { echo "[release] Resources/exiftool missing — run scripts/bootstrap.sh" >&2; exit 1; }

# ── 1. Derive version from git ──────────────────────────────────────────────
COMMITS=$(git rev-list --count HEAD)
SHA9=$(git rev-parse --short=9 HEAD)
DIRTY=""
if [[ -n "$(git status --porcelain)" ]]; then
  DIRTY="-dirty"
fi
MARKETING="0.${COMMITS}.0"
BUILD="${COMMITS}"
DESCRIBE="v${MARKETING}-${SHA9}${DIRTY}"
TAG="v${MARKETING}"

if [[ -n "$DIRTY" && $VERIFY_ONLY -eq 0 && $DRY_RUN -eq 0 ]]; then
  echo "[release] refusing to cut a release from a dirty tree. Commit or stash first." >&2
  exit 2
fi

echo "[release] $DESCRIBE  (marketing=$MARKETING build=$BUILD)"

# ── 2. Archive + extract .app ───────────────────────────────────────────────
# We deliberately skip `xcodebuild -exportArchive` because for phase 3a
# (ad-hoc / unsigned) it needs no Developer ID team and just gets in the way.
# Copy the .app out of the xcarchive directly, then ad-hoc sign in step 5.
echo "[release] archive"
rm -rf build/export build/PhotoX.xcarchive
xcodebuild -project PhotoX.xcodeproj -scheme PhotoX -configuration Release \
  -archivePath build/PhotoX.xcarchive archive \
  -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$MARKETING" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  GIT_DESCRIBE="$DESCRIBE" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  >/dev/null

ARCHIVED_APP="build/PhotoX.xcarchive/Products/Applications/PhotoX.app"
test -d "$ARCHIVED_APP" || { echo "[release] archive missing $ARCHIVED_APP" >&2; exit 3; }

mkdir -p build/export
cp -R "$ARCHIVED_APP" build/export/
APP="build/export/PhotoX.app"

# ── 3. Static self-containment checks ───────────────────────────────────────
echo "[release] static self-containment check"

BAD_MAIN=$(otool -L "$APP/Contents/MacOS/PhotoX" \
  | grep -E '/opt/homebrew/|/usr/local/|libraw' || true)

BAD_RECURSIVE=""
while IFS= read -r MACHO; do
  HITS=$(otool -L "$MACHO" 2>/dev/null \
    | grep -E '/opt/homebrew/|/usr/local/|libraw' || true)
  if [[ -n "$HITS" ]]; then
    BAD_RECURSIVE+=$'\n--- '"$MACHO"$'\n'"$HITS"
  fi
done < <(find "$APP" -type f -perm +111 -exec file {} + \
         | grep -E 'Mach-O' | awk -F: '{print $1}')

BAD_STRINGS=$(strings "$APP/Contents/MacOS/PhotoX" \
  | grep -E '^(/opt/homebrew|/usr/local)' || true)

EXIFTOOL_OK="no"
test -x "$APP/Contents/Resources/exiftool/exiftool" && EXIFTOOL_OK="yes"

if [[ -n "$BAD_MAIN$BAD_RECURSIVE$BAD_STRINGS" || "$EXIFTOOL_OK" != "yes" ]]; then
  echo "[release] FAIL: self-containment check" >&2
  [[ -n "$BAD_MAIN" ]]      && { echo "  main exec links Homebrew/libraw:" >&2; echo "$BAD_MAIN" >&2; }
  [[ -n "$BAD_RECURSIVE" ]] && { echo "  embedded Mach-O hits:" >&2;             echo "$BAD_RECURSIVE" >&2; }
  [[ -n "$BAD_STRINGS" ]]   && { echo "  hardcoded path strings:" >&2;           echo "$BAD_STRINGS" >&2; }
  [[ "$EXIFTOOL_OK" != "yes" ]] && echo "  bundled exiftool missing or not executable" >&2
  exit 4
fi
echo "  ✓ no Homebrew/libraw refs anywhere in bundle"
echo "  ✓ no hardcoded /opt/homebrew or /usr/local strings in main binary"
echo "  ✓ Resources/exiftool/exiftool present + executable"

# ── 4. Tests + verify-only short-circuit ────────────────────────────────────
if [[ $VERIFY_ONLY -eq 1 ]]; then
  echo "[release] running BundledResourcesTests (Debug)"
  # Tests are built against the Debug config since @testable + Release modules
  # don't compose. The Debug build still copies the bundled exiftool into
  # PhotoX.app, which is what the tests assert against.
  xcodebuild -project PhotoX.xcodeproj -scheme PhotoX -configuration Debug \
    test -only-testing:PhotoXTests/BundledResourcesTests \
    >/dev/null
  echo "[release] verify-only OK"
  exit 0
fi

# ── 5. Ad-hoc codesign (phase 3a) ───────────────────────────────────────────
# When Developer ID enrollment lands, replace this block with:
#   codesign --force --deep --sign "Developer ID Application: <Name> (TEAMID)" \
#     --options runtime --timestamp \
#     --entitlements PhotoX/PhotoX.entitlements "$APP"
#   xcrun notarytool submit "$APP" --apple-id "$APPLE_ID" --team-id TEAMID \
#     --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
#   xcrun stapler staple "$APP"
echo "[release] ad-hoc codesign"
# Sparkle ships pre-signed with its maintainers' Team ID. macOS's hardened
# runtime refuses to load a framework whose Team ID differs from the host
# binary's, and `--deep` is unreliable at rebadging nested .xpc/.app/.framework
# bundles. So: strip every existing signature inside the .app, then sign from
# inside-out with the ad-hoc identity, then seal the outer app last.
find "$APP" -path '*/_CodeSignature' -type d -prune -exec rm -rf {} +

# Re-sign all nested Mach-O bundles (xpc → app → framework), depth-first.
while IFS= read -r BUNDLE; do
  codesign --force --sign - --options runtime --timestamp=none "$BUNDLE"
done < <(find "$APP/Contents/Frameworks" \
  \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) \
  -type d -depth 2>/dev/null)

# Seal the outer app last, with the hardened-runtime entitlements.
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements PhotoX/PhotoX.entitlements "$APP"

# ── 6. DMG ──────────────────────────────────────────────────────────────────
DMG_NAME="PhotoX-${DESCRIBE}.dmg"
DMG="build/$DMG_NAME"
rm -f "$DMG"
echo "[release] dmg → $DMG"
hdiutil create -volname "PhotoX" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
SIZE=$(stat -f%z "$DMG")

# ── 7. Sparkle EdDSA sign ───────────────────────────────────────────────────
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*Sparkle*/bin/sign_update' 2>/dev/null | head -1)
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "[release] sign_update helper not found — has Sparkle been resolved?" >&2
  exit 5
fi
# sign_update emits both sparkle:edSignature="..." AND length="..." attributes,
# so don't double-emit length= ourselves.
SIG_BLOB=$("$SIGN_UPDATE" "$DMG")

PUBDATE=$(date -R)
SNIPPET="    <item>
      <title>$DESCRIBE</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$MARKETING</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure
        url=\"https://github.com/Frostman/photo-x/releases/download/$TAG/$DMG_NAME\"
        type=\"application/octet-stream\"
        $SIG_BLOB />
    </item>"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[release] dry-run; not committing, pushing, or publishing"
  echo "--- snippet ---"
  echo "$SNIPPET"
  exit 0
fi

# ── 8. Splice into docs/appcast.xml, commit, push, publish ──────────────────
echo "[release] splice appcast"
SNIPPET_FILE=$(mktemp)
trap 'rm -f "$SNIPPET_FILE" docs/appcast.xml.new' EXIT
printf '%s\n' "$SNIPPET" > "$SNIPPET_FILE"
# Splice the snippet just before </channel>. BSD awk on macOS can't handle
# embedded newlines in -v values, so use sed + assembly via three streams.
{
  sed -n '/<\/channel>/,$!p' docs/appcast.xml  # everything before </channel>
  cat "$SNIPPET_FILE"                          # the new <item>
  sed -n '/<\/channel>/,$p' docs/appcast.xml   # </channel> and below
} > docs/appcast.xml.new
mv docs/appcast.xml.new docs/appcast.xml
rm -f "$SNIPPET_FILE"
trap - EXIT

git add docs/appcast.xml
git -c commit.gpgsign=false commit -m "Release $DESCRIBE"
git push

# Release notes from commits since the previous v0.*.0 tag (skip the one we
# just may have created via git push if a CI added it).
PREV_TAG=$(git tag --list 'v0.*' --sort=-v:refname | grep -v "^$TAG$" | head -1)
if [[ -n "$PREV_TAG" ]]; then
  NOTES=$(git log --pretty='format:- %s' "$PREV_TAG..HEAD" | head -50)
else
  NOTES="Initial release."
fi

echo "[release] gh release create $TAG"
gh release create "$TAG" \
  --title "$DESCRIBE" \
  --notes "$NOTES" \
  "$DMG"

echo "[release] DONE"
echo "[release] Tag:     $TAG"
echo "[release] Release: https://github.com/Frostman/photo-x/releases/tag/$TAG"
echo "[release] Appcast: https://raw.githubusercontent.com/Frostman/photo-x/master/docs/appcast.xml (live within ~5 min of push)"
