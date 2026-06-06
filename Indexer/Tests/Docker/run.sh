#!/bin/sh
# Smoke tests for the cross-compiled `photox` binary. Runs inside
# the Docker container built from this directory's Dockerfile —
# launched by `just linux-test` from the repo root.
#
# Goal isn't comprehensive correctness (CoordinatorParityTests
# covers that on the host). It's proving the static binary actually
# runs on a vanilla Linux kernel: env-var version resolution, the
# subcommand dispatcher, PosixExec spawn against the alpine
# exiftool, and PropertyListEncoder binary output.
set -eu

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf '✓ %s\n' "$1"; }

# ── Test 1: --version exits 0 and prints something ─────────────────────────
out=$(photox --version)
[ -n "$out" ] || fail "--version printed nothing"
pass "--version → '$out'"

# ── Test 2: no args → top-level usage on stderr, exit 2 ────────────────────
if photox >/dev/null 2>&1; then
    fail "no-args run unexpectedly exited 0"
fi
photox >/dev/null 2>err.txt && rc=$? || rc=$?
[ "$rc" -eq 2 ] || fail "no-args exit code was $rc (expected 2)"
grep -q 'Usage: photox' err.txt || fail "no-args stderr missing 'Usage: photox'"
pass "no-args → exit 2 + usage"

# ── Test 3: unknown command → exit 2 with helpful error ────────────────────
photox bogus >/dev/null 2>err.txt && rc=$? || rc=$?
[ "$rc" -eq 2 ] || fail "unknown-command exit code was $rc (expected 2)"
grep -q 'unknown command: bogus' err.txt || fail "unknown-command stderr missing the hint"
pass "unknown command → exit 2 + 'unknown command' hint"

# ── Test 4: index of an empty dir → exit 1 + 'No … entries' message ────────
mkdir -p /test/empty
photox index /test/empty >/dev/null 2>err.txt && rc=$? || rc=$?
[ "$rc" -eq 1 ] || fail "empty-dir index exit code was $rc (expected 1)"
grep -q 'No ARW' err.txt || fail "empty-dir stderr missing 'No ARW' message"
pass "index empty dir → exit 1"

# ── Test 5: full end-to-end with a minimal real JPEG ───────────────────────
#
# This is the most load-bearing test: it proves the static binary
# can fork+execve exiftool (the path that broke on NixOS pre-PosixExec)
# and that PropertyListEncoder's binary plist output works under
# swift-corelibs-foundation static-musl.
#
# We use exiftool itself (already installed for the binary to call)
# to generate a 1×1 JPEG with valid EXIF — that gives us a single-
# entry shoot folder the indexer can actually process.
mkdir -p /test/shoot
# Minimal JPEG: ImageMagick isn't installed in this image, but
# exiftool can copy tags FROM a tiny fixture. Easier: just write a
# known-good tiny JPEG byte-for-byte via printf. 134 bytes, 1×1,
# no EXIF — the indexer's JPEG path returns thumbnailJPEG=nil but
# still produces a sidecar entry (we just want any valid file).
printf '\xff\xd8\xff\xdb\x00\x43\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\x09\x09\x08\x0a\x0c\x14\x0d\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a\x1f\x1e\x1d\x1a\x1c\x1c\x20\x24\x2e\x27\x20\x22\x2c\x23\x1c\x1c\x28\x37\x29\x2c\x30\x31\x34\x34\x34\x1f\x27\x39\x3d\x38\x32\x3c\x2e\x33\x34\x32\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xc4\x00\x14\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xc4\x00\x14\x10\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x37\xff\xd9' > /test/shoot/IMG_0001.JPG
# Stamp it with EXIF Make/Model so the exiftool path has something
# to scrape. Avoids the 'no Sony tags' branch.
exiftool -overwrite_original -Make=TestCam -Model=TestModel /test/shoot/IMG_0001.JPG >/dev/null

# Run the indexer.
photox index /test/shoot 2>&1 | grep -q 'Indexed 1 entries' \
    || fail "index <shoot> didn't print 'Indexed 1 entries'"

# Sidecar must exist + be non-empty.
[ -f /test/shoot/.photox-index.plist ] || fail "sidecar plist missing"
size=$(wc -c < /test/shoot/.photox-index.plist)
[ "$size" -gt 0 ] || fail "sidecar plist is empty"
pass "index <single-JPG> → exit 0 + sidecar ($size bytes)"

# Sanity-check the sidecar is a binary plist (starts with 'bplist').
head -c 6 /test/shoot/.photox-index.plist | grep -q 'bplist' \
    || fail "sidecar isn't a binary plist (header mismatch)"
pass "sidecar header = bplist00"

printf '\n✓ All linux-test smoke checks passed\n'
