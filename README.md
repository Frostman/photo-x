# PhotoX

A macOS culling viewer for Sony A1 II shoots. Pairs `.ARW` RAW + `.HIF` HEIF
files; HEIF previews instantly, RAW decodes on demand via vendored LibRaw.
Decisions (ratings, color labels, reject) persist to XMP sidecars compatible
with Lightroom.

## Requirements

- macOS 26.0+ (Apple Silicon)
- Xcode 26+ command-line tools

## Build from source

```sh
brew install xcodegen gh
./scripts/bootstrap.sh           # builds static LibRaw + fetches ExifTool
open PhotoX.xcodeproj             # build & run from Xcode (⌘R)
```

`scripts/bootstrap.sh` is idempotent and hermetic — it only writes inside the
repo, never `sudo`.

## Cut a release

```sh
./scripts/release.sh
```

Version is derived from git (`v0.<commit-count>.0-<sha9>`); never hand-bumped.
The script archives, ad-hoc signs, builds a `.dmg`, EdDSA-signs it with
Sparkle, splices an entry into `docs/appcast.xml`, commits + pushes, and
creates a GitHub Release.

## Auto-update

Running PhotoX checks `https://raw.githubusercontent.com/Frostman/photo-x/master/docs/appcast.xml`
once a day and offers updates via **PhotoX → Check for Updates…** (Sparkle 2).

## License

PhotoX is published under the [Apache License 2.0](LICENSE).

Third-party components bundled with the app:

- **Sparkle** (auto-update) — MIT
- **LibRaw** (RAW decoder) — LGPL 2.1, selected from LibRaw's dual
  LGPL / CDDL / commercial license
- **ExifTool** by Phil Harvey (metadata) — Artistic License 1.0,
  selected from ExifTool's dual Artistic / GPL license

See [NOTICE](NOTICE) for attribution details and
[THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/) for full license texts.
The shipped `.app` carries the same texts at
`PhotoX.app/Contents/Resources/Licenses/`; PhotoX → About PhotoX
surfaces a short attribution panel inline.
