# Switch PhotoX to Developer ID signing + notarization

## Context

PhotoX currently ships as an ad-hoc-signed `.app` inside an unsigned DMG, with
`com.apple.security.cs.disable-library-validation` granted so the hardened
runtime will load the (also ad-hoc) Sparkle.framework. Gatekeeper rejects this
on first launch on any Mac other than the one that built it, forcing users
through a right-click → Open dance.

The user now has an Apple Developer account. Switching to "Developer ID
Application" signing + Apple notarization + stapling means a one-double-click
install with no Gatekeeper warning, and lets us drop the
`disable-library-validation` exception (Sparkle inherits our Team ID when we
deep-sign with our Developer ID).

The migration is already pre-staged in `scripts/release.sh:128-135` as a
comment block — this plan implements it for real, plus DMG signing /
notarization / stapling and a clean separation of Debug-build needs.

## Decisions (locked)

- **Credentials**: App Store Connect API key (`.p8`), stored once in the
  keychain via `xcrun notarytool store-credentials`.
- **Config source**: `scripts/release.local.env` (gitignored), sourced by
  `release.sh`. Holds `DEVELOPER_ID_APPLICATION` + `NOTARYTOOL_KEYCHAIN_PROFILE`.
- **Dev builds (`just dev`)**: stay ad-hoc. Split entitlements into a
  Release file (no library-validation exception) and a Debug file (keeps it).
- **DMG flow**: sign + notarize + staple the `.app` first, then sign +
  notarize + staple the DMG. Sparkle EdDSA signs the stapled DMG.

## File changes

### 1. New: `PhotoX/PhotoX-Debug.entitlements`

Identical to today's `PhotoX.entitlements`. Keeps
`com.apple.security.cs.disable-library-validation` so ad-hoc dev builds can
still load the ad-hoc-signed Sparkle.framework. Wired in only for Debug.

### 2. Modify: `PhotoX/PhotoX.entitlements`

Remove the `com.apple.security.cs.disable-library-validation` key (and its
comment). Leaves an empty `<dict/>` — codesign still embeds it and the
hardened runtime stays on via `ENABLE_HARDENED_RUNTIME=YES` /
`--options runtime`. Update the file-top comment to note this is the Release
entitlements file; Debug uses `PhotoX-Debug.entitlements`.

### 3. Modify: `project.yml`

In `targets.PhotoX.settings.configs`:
- `Debug`: add `CODE_SIGN_ENTITLEMENTS: PhotoX/PhotoX-Debug.entitlements`
- `Release`: leave the base `CODE_SIGN_ENTITLEMENTS: PhotoX/PhotoX.entitlements`
  applied (no change needed)

No `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` baked into the project — release
signing is driven entirely by `release.sh` so the project file stays free of
personal identifiers.

### 4. Modify: `scripts/release.sh`

**Top (after prerequisite checks, before version derivation):** add a new
"Load release-local config" section.

- Source `scripts/release.local.env` if it exists; require
  `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_KEYCHAIN_PROFILE` to be set.
  Skip both requirements when `--verify-only` (verify-only does not sign).
- Pre-flight: `security find-identity -v -p codesigning | grep -qF
  "$DEVELOPER_ID_APPLICATION"`; fail with a clear hint pointing at
  Xcode → Settings → Accounts → Manage Certificates if missing.
- Pre-flight: `xcrun notarytool history --keychain-profile
  "$NOTARYTOOL_KEYCHAIN_PROFILE" --output-format json >/dev/null` to validate
  the keychain profile is readable; fail with a hint pointing at
  `notarytool store-credentials` if missing.

**Section §5 (ad-hoc codesign):** replace entirely with Developer ID codesign.
Keep the existing strip-then-resign-inside-out walk over
`Contents/Frameworks/*.{xpc,app,framework}` — it's still correct, just swap
the identity and flags:
- Strip `_CodeSignature` dirs as today.
- For each nested bundle: `codesign --force --sign
  "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$BUNDLE"`
  (drop `=none` from `--timestamp` — secure timestamp is mandatory for
  notarization).
- Seal outer app with `--entitlements PhotoX/PhotoX.entitlements
  --options runtime --timestamp`.
- Verify: `codesign --verify --deep --strict --verbose=2 "$APP"`.

**New section §5b (notarize .app):**
- Zip the .app to `build/PhotoX.app.zip` with `ditto -c -k --keepParent`
  (notarytool only accepts .zip/.dmg/.pkg).
- `xcrun notarytool submit build/PhotoX.app.zip --keychain-profile
  "$NOTARYTOOL_KEYCHAIN_PROFILE" --wait` — capture submission ID.
- On non-`Accepted` status, fetch and print `xcrun notarytool log
  <submission-id> --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE"` then
  exit non-zero.
- Delete the zip.

**New section §5c (staple .app):**
- `xcrun stapler staple "$APP"`
- `spctl --assess --type exec -vv "$APP"` → expect "accepted … source=Notarized
  Developer ID".

**Section §6 (DMG) unchanged** — staged .app is now signed/notarized/stapled.

**New section §6b (sign DMG):**
- `codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"`.

**New section §6c (notarize DMG):**
- `xcrun notarytool submit "$DMG" --keychain-profile
  "$NOTARYTOOL_KEYCHAIN_PROFILE" --wait`; same log-on-failure handling as §5b.

**New section §6d (staple DMG):**
- `xcrun stapler staple "$DMG"`
- `spctl --assess --type open --context context:primary-signature -vv "$DMG"`.

**Section §7 (Sparkle EdDSA sign) unchanged** — happens after staple so the
stapled DMG is what gets hashed (matches what users download).

**Section §8 (publish) unchanged.**

### 5. Modify: `.gitignore`

Add `scripts/release.local.env`.

### 6. New: `scripts/release.local.env.example`

Template with placeholder values:
```sh
# Copy to scripts/release.local.env (gitignored) and fill in.
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
NOTARYTOOL_KEYCHAIN_PROFILE="PhotoX-Notarize"
```

### 7. Modify: `README.md`

Update the release section to document:
- The one-time signing/notarization setup (see below).
- That `just release` now produces a Developer-ID-signed, notarized, stapled
  DMG with no Gatekeeper warning on first launch.

## One-time setup (user runs once)

1. **Install Developer ID Application certificate**:
   Xcode → Settings → Accounts → select Apple ID → Manage Certificates… → "+"
   → "Developer ID Application". (Or download `.cer` from developer.apple.com
   → Certificates and double-click to install.)
   Verify: `security find-identity -v -p codesigning` shows
   `Developer ID Application: Sergei Lukianov (TEAMID)`.

2. **Create App Store Connect API key**:
   https://appstoreconnect.apple.com/access/api → Keys → "+" → access role
   "Developer" → download the `AuthKey_XXXXXXXXXX.p8` (one-time download).
   Note the Key ID (10 chars) and Issuer ID (UUID at the top of the page).

3. **Register the key with notarytool**:
   ```sh
   xcrun notarytool store-credentials "PhotoX-Notarize" \
     --key ~/path/to/AuthKey_XXXXXXXXXX.p8 \
     --key-id XXXXXXXXXX \
     --issuer YOUR-ISSUER-UUID
   ```

4. **Create `scripts/release.local.env`** from the `.example`, filling in the
   Developer ID Application identity string and the keychain profile name.

## Critical files

- `scripts/release.sh` — main changes (~80 lines added/changed)
- `PhotoX/PhotoX.entitlements` — drop library-validation key
- `PhotoX/PhotoX-Debug.entitlements` — new, keeps it for ad-hoc Debug
- `project.yml:119-122` — per-config entitlements override for Debug
- `.gitignore` — add `scripts/release.local.env`
- `scripts/release.local.env.example` — new template
- `README.md:24-33` — update release docs

## Verification

1. **`just bootstrap`** — regenerate xcodeproj with the per-config entitlements.
2. **`just dev`** — confirm dev build still launches (ad-hoc + Debug
   entitlements; Sparkle.framework still loads).
3. **`just release --verify-only`** — confirms prereq checks still pass on a
   clean tree and the bundled-resources test suite still runs (this path
   does *not* exercise signing/notarization).
4. **`just release --dry-run`** — full end-to-end except the GitHub publish:
   archives, Developer ID signs, notarizes .app, staples, builds DMG, signs
   DMG, notarizes DMG, staples DMG, Sparkle-signs, generates appcast snippet.
   Manual checks against the produced artifacts:
   - `codesign -dvvv build/export/PhotoX.app` → `Authority=Developer ID
     Application: Sergei Lukianov (TEAMID)`, `TeamIdentifier=TEAMID`.
   - `codesign --verify --deep --strict --verbose=2 build/export/PhotoX.app`
     → no errors.
   - `xcrun stapler validate build/export/PhotoX.app` → "The validate action
     worked!".
   - `spctl --assess -t exec -vv build/export/PhotoX.app` → "accepted …
     source=Notarized Developer ID".
   - `spctl --assess -t open --context context:primary-signature -vv
     build/PhotoX-*.dmg` → "accepted".
   - Move the DMG to a second Mac (or just `xattr -w
     com.apple.quarantine "0083;…;Safari;…" build/PhotoX-*.dmg` to simulate a
     download), double-click, drag to Applications, launch → no Gatekeeper
     warning.
5. **`just release`** — cut a real release once the dry-run is green.

## Out of scope

- Mac App Store distribution (different cert family, different entitlements,
  sandbox requirements).
- Notarization of intermediate dev artifacts.
- Migrating away from Sparkle for updates.
- Code signing the test bundle.
