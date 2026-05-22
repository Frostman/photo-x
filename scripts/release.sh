#!/bin/bash
# Cuts a release of PhotoX. Version is derived entirely from git — never
# hand-bumped. Builds, Developer-ID-signs the .app + nested
# .xpc/.app/.framework bundles, notarizes + staples the .app, packages a
# notarized + stapled DMG, signs it with Sparkle's EdDSA key, splices an
# entry into docs/appcast.xml, commits + pushes, and creates a GitHub
# Release via `gh`. Hermetic to this repo — no sudo, no writes outside
# the repo.
#
# Signing requires scripts/release.local.env (gitignored — see
# release.local.env.example). One-time setup steps are in README.md
# under "Cutting a release".
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

# ── 0. Load release-local signing config ────────────────────────────────────
# verify-only doesn't sign anything; skip the requirement.
if [[ $VERIFY_ONLY -eq 0 ]]; then
  ENV_FILE="scripts/release.local.env"
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "[release] $ENV_FILE missing — copy scripts/release.local.env.example and fill in." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  : "${DEVELOPER_ID_APPLICATION:?[release] DEVELOPER_ID_APPLICATION not set in $ENV_FILE}"
  : "${NOTARYTOOL_KEYCHAIN_PROFILE:?[release] NOTARYTOOL_KEYCHAIN_PROFILE not set in $ENV_FILE}"

  if ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID_APPLICATION"; then
    echo "[release] codesigning identity not found: $DEVELOPER_ID_APPLICATION" >&2
    echo "[release] hint: Xcode → Settings → Accounts → Manage Certificates → '+' → 'Developer ID Application'" >&2
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" --output-format json >/dev/null 2>&1; then
    echo "[release] notarytool keychain profile '$NOTARYTOOL_KEYCHAIN_PROFILE' missing or invalid." >&2
    echo "[release] hint: xcrun notarytool store-credentials \"$NOTARYTOOL_KEYCHAIN_PROFILE\" --key … --key-id … --issuer …" >&2
    exit 1
  fi
  echo "[release] signing identity: $DEVELOPER_ID_APPLICATION"
  echo "[release] notary profile:   $NOTARYTOOL_KEYCHAIN_PROFILE"
fi

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

# ── 5. Developer ID codesign ────────────────────────────────────────────────
# Sparkle ships pre-signed with its maintainers' Team ID. The hardened
# runtime refuses to load a framework whose Team ID differs from the
# host binary's, and `--deep` is unreliable at rebadging nested
# .xpc/.app/.framework bundles. Strip every existing signature inside
# the .app, then sign from inside-out with OUR Developer ID, then seal
# the outer app last (with --options runtime so the hardened runtime
# enforces library validation against our Team ID).
echo "[release] Developer ID codesign"
find "$APP" -path '*/_CodeSignature' -type d -prune -exec rm -rf {} +

while IFS= read -r BUNDLE; do
  # --deep here applies only to THIS bundle's subtree (catches bare
  # Mach-O helpers like Sparkle.framework/Versions/B/Autoupdate that
  # aren't .xpc/.app/.framework themselves). NOT applied to the outer
  # app — that one gets sealed below with an explicit (non-deep) pass.
  codesign --force --deep \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --options runtime \
    --timestamp \
    "$BUNDLE"
done < <(find "$APP/Contents/Frameworks" \
  \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) \
  -type d -depth 2>/dev/null)

# Seal the outer app last, with the (now-empty Release) entitlements
# applied.
codesign --force \
  --sign "$DEVELOPER_ID_APPLICATION" \
  --options runtime \
  --timestamp \
  --entitlements PhotoX/PhotoX.entitlements \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# ── 5b. Notarize .app ───────────────────────────────────────────────────────
# notarytool only accepts .zip/.dmg/.pkg, so wrap the .app first.
# `ditto -c -k --keepParent` makes a zip that, when extracted, recreates
# the PhotoX.app folder (preserves symlinks, extended attributes, etc).
APP_ZIP="build/PhotoX.app.zip"
rm -f "$APP_ZIP"
echo "[release] notarize .app (uploading…)"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
SUBMIT_OUT=$(xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
  --wait \
  --output-format json)
echo "$SUBMIT_OUT" | sed 's/^/  /'
SUBMIT_ID=$(echo "$SUBMIT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
STATUS=$(echo "$SUBMIT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
if [[ "$STATUS" != "Accepted" ]]; then
  echo "[release] notarization status: $STATUS — fetching log:" >&2
  xcrun notarytool log "$SUBMIT_ID" \
    --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" >&2
  exit 6
fi
rm -f "$APP_ZIP"

# ── 5c. Staple .app ─────────────────────────────────────────────────────────
echo "[release] staple .app"
xcrun stapler staple "$APP" 2>&1 | sed 's/^/  /'
spctl --assess --type exec -vv "$APP" 2>&1 | sed 's/^/  /'

# ── 6. DMG ──────────────────────────────────────────────────────────────────
# Stage the .app alongside an /Applications symlink so the mounted DMG shows
# both side-by-side and the user can drag PhotoX → Applications inside the
# DMG window (standard macOS install affordance).
DMG_NAME="PhotoX-${DESCRIBE}.dmg"
DMG="build/$DMG_NAME"
STAGE="build/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
echo "[release] dmg → $DMG"
hdiutil create -volname "PhotoX" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# ── 6b. Sign DMG ────────────────────────────────────────────────────────────
echo "[release] sign dmg"
codesign --force \
  --sign "$DEVELOPER_ID_APPLICATION" \
  --timestamp \
  "$DMG"

# ── 6c. Notarize DMG ────────────────────────────────────────────────────────
echo "[release] notarize dmg (uploading…)"
DMG_SUBMIT_OUT=$(xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
  --wait \
  --output-format json)
echo "$DMG_SUBMIT_OUT" | sed 's/^/  /'
DMG_SUBMIT_ID=$(echo "$DMG_SUBMIT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
DMG_STATUS=$(echo "$DMG_SUBMIT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
if [[ "$DMG_STATUS" != "Accepted" ]]; then
  echo "[release] DMG notarization status: $DMG_STATUS — fetching log:" >&2
  xcrun notarytool log "$DMG_SUBMIT_ID" \
    --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" >&2
  exit 7
fi

# ── 6d. Staple DMG ──────────────────────────────────────────────────────────
echo "[release] staple dmg"
xcrun stapler staple "$DMG" 2>&1 | sed 's/^/  /'
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'

# Capture final size for the appcast enclosure AFTER staple, since
# stapler rewrites the file.
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

# Release notes: derived from `git log PREV_TAG..HEAD`. Used in two
# places below — the appcast <description> (rendered in the in-app
# update popup) and the GitHub Release body (rendered on the
# Releases page). One source so both stay in lockstep.
# We use `gh release list` rather than `git tag` because tags are
# created on GitHub (by `gh release create`) and never fetched back
# locally. `|| true` guards against pipefail when there are no prior
# releases.
PREV_TAG=$(gh release list --limit 5 --json tagName --jq '.[].tagName' 2>/dev/null \
  | grep -v "^$TAG$" \
  | head -1 || true)
if [[ -n "$PREV_TAG" ]] && git rev-parse --verify "$PREV_TAG" >/dev/null 2>&1; then
  NOTES_PLAIN=$(git log --pretty='format:- %s' "$PREV_TAG..HEAD" | head -50)
  NOTES_HTML="<ul>$(git log --pretty='format:<li>%s</li>' "$PREV_TAG..HEAD" \
    | head -50 | tr -d '\n')</ul>"
elif [[ -n "$PREV_TAG" ]]; then
  NOTES_PLAIN="See appcast.xml for the EdDSA-signed download.

Diff vs previous release: https://github.com/Frostman/photo-x/compare/$PREV_TAG...$TAG"
  NOTES_HTML="<p>Diff vs previous release: <a href=\"https://github.com/Frostman/photo-x/compare/$PREV_TAG...$TAG\">$PREV_TAG → $TAG</a></p>"
else
  NOTES_PLAIN="Initial release."
  NOTES_HTML="<p>Initial release.</p>"
fi

PUBDATE=$(date -R)
SNIPPET="    <item>
      <title>$DESCRIBE</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$MARKETING</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
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

# Reuse the bullets we already built above for the appcast
# <description> — keeps the in-app popup and the GitHub Release page
# in lockstep.
echo "[release] gh release create $TAG"
gh release create "$TAG" \
  --title "$DESCRIBE" \
  --notes "$NOTES_PLAIN" \
  "$DMG"

echo "[release] DONE"
echo "[release] Tag:     $TAG"
echo "[release] Release: https://github.com/Frostman/photo-x/releases/tag/$TAG"
echo "[release] Appcast: https://raw.githubusercontent.com/Frostman/photo-x/master/docs/appcast.xml (live within ~5 min of push)"
