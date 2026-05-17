#!/bin/bash
# Idempotent: materialises ThirdParty/libraw/ + Resources/exiftool/, then regenerates the Xcode project.
# Hermetic to this repo — never writes outside $(git rev-parse --show-toplevel), never runs sudo.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

LIBRAW_VERSION="0.21.4"
# exiftool.org only keeps the latest production release at a known URL;
# discover it from the homepage instead of pinning a version that 404s later.

FORCE=0
VERIFY=0
for a in "$@"; do
  case "$a" in
    --force)  FORCE=1 ;;
    --verify) VERIFY=1 ;;
    *) echo "usage: $0 [--force] [--verify]" >&2; exit 2 ;;
  esac
done

command -v xcodegen >/dev/null || { echo "[bootstrap] xcodegen missing (brew install xcodegen)" >&2; exit 1; }
command -v curl     >/dev/null || { echo "[bootstrap] curl missing" >&2; exit 1; }
command -v tar      >/dev/null || { echo "[bootstrap] tar missing" >&2; exit 1; }

# ── LibRaw ──────────────────────────────────────────────────────────────────
if [[ $FORCE -eq 1 || ! -f ThirdParty/libraw/lib/libraw_r.a ]]; then
  echo "[bootstrap] building LibRaw $LIBRAW_VERSION (static, deps-disabled)"
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  (
    cd "$WORK"
    curl -fsSL "https://www.libraw.org/data/LibRaw-${LIBRAW_VERSION}.tar.gz" | tar xz
    cd "LibRaw-${LIBRAW_VERSION}"
    ./configure \
      --enable-static --disable-shared \
      --disable-examples \
      --disable-jpeg --disable-jasper --disable-lcms \
      --disable-openmp \
      CFLAGS="-arch arm64 -O3" CXXFLAGS="-arch arm64 -O3" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
  )
  rm -rf ThirdParty/libraw
  mkdir -p ThirdParty/libraw/lib ThirdParty/libraw/include/libraw
  cp "$WORK/LibRaw-${LIBRAW_VERSION}/lib/.libs/libraw_r.a" ThirdParty/libraw/lib/
  cp "$WORK/LibRaw-${LIBRAW_VERSION}/libraw/"*.h           ThirdParty/libraw/include/libraw/
  rm -rf "$WORK"
  trap - EXIT
  echo "[bootstrap]   → ThirdParty/libraw/lib/libraw_r.a ($(stat -f%z ThirdParty/libraw/lib/libraw_r.a) bytes)"
else
  echo "[bootstrap] LibRaw cached (use --force to rebuild)"
fi

# ── ExifTool ────────────────────────────────────────────────────────────────
if [[ $FORCE -eq 1 || ! -x Resources/exiftool/exiftool ]]; then
  EXIFTOOL_VERSION=$(curl -fsSL https://exiftool.org/ \
    | grep -oE 'Image-ExifTool-[0-9.]+\.tar\.gz' \
    | head -1 \
    | sed -E 's/Image-ExifTool-([0-9.]+)\.tar\.gz/\1/')
  if [[ -z "$EXIFTOOL_VERSION" ]]; then
    echo "[bootstrap] could not discover ExifTool version from exiftool.org" >&2
    exit 1
  fi
  echo "[bootstrap] fetching ExifTool $EXIFTOOL_VERSION"
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  curl -fsSL "https://exiftool.org/Image-ExifTool-${EXIFTOOL_VERSION}.tar.gz" \
    | tar xz -C "$WORK"
  rm -rf Resources/exiftool
  mkdir -p Resources/exiftool
  cp    "$WORK/Image-ExifTool-${EXIFTOOL_VERSION}/exiftool" Resources/exiftool/
  cp -R "$WORK/Image-ExifTool-${EXIFTOOL_VERSION}/lib"      Resources/exiftool/
  chmod +x Resources/exiftool/exiftool
  rm -rf "$WORK"
  trap - EXIT
  VER_OUT=$(/usr/bin/perl Resources/exiftool/exiftool -ver 2>/dev/null || echo "?")
  echo "[bootstrap]   → Resources/exiftool/exiftool (Image::ExifTool $VER_OUT)"
else
  echo "[bootstrap] ExifTool cached (use --force to refetch)"
fi

# ── Project regen ───────────────────────────────────────────────────────────
echo "[bootstrap] xcodegen"
xcodegen >/dev/null

# ── Optional verification ───────────────────────────────────────────────────
if [[ $VERIFY -eq 1 ]]; then
  echo "[bootstrap] running release.sh --verify-only"
  bash scripts/release.sh --verify-only
fi

echo "[bootstrap] OK"
