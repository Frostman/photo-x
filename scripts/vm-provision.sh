#!/bin/bash
# vm-provision.sh — first-launch setup INSIDE the Tart VM.
#
# Streamed in by scripts/vm-remote.sh via `tart exec ... bash -s`. This
# script never runs on the host (a hard guard at the top refuses
# otherwise). The VM is a pure XCUITest runner: the app + test
# bundles + xctestrun + sample fixture are built and shipped from the
# host. The VM only needs enough state to drive
# `xcodebuild test-without-building` without prompts.
#
# What this DOESN'T install (intentionally):
#   - Homebrew formulae (just, xcodegen, coreutils) — not needed; the
#     VM never builds the project.
#   - Bootstrap deps (LibRaw, ExifTool) — they're statically linked
#     and bundled into PhotoX.app on the host.
#   - Swift Package Manager prewarm — SPM resolution happens on host
#     in cmd_ship; the VM's test-without-building uses prebuilt .app.
#
# What this DOES install:
#   - TCC accessibility row for the Xcode test runner (so XCUITest
#     can drive the app without a System Settings click).
#   - Host SSH public key (primary transport for ssh-rsync of
#     artifacts + sample).
#   - Xcode license acceptance + DevToolsSecurity + _developer group
#     membership for admin (so the headless user can drive
#     xcodebuild).
#   - Background Task Management reset (PhotoX.app embeds the card-
#     watcher LoginItem; this prevents a system approval banner from
#     interrupting XCUITest on first launch).
#
# Idempotent. Safe to re-run via
# `rm /Users/admin/.photox-vm-provisioned && just vm-up`.
#
# Credentials: this script references `admin/admin` (Cirrus image
# default). VM-internal-only, not reachable from any public network.
# SSH key auth is set up as the primary transport; password remains
# available as a fallback (`just vm-shell`).
set -euo pipefail

MARKER=/Users/admin/.photox-vm-provisioned
PUBKEY_INBOX=/tmp/photox-bootstrap/host-pubkey
log() { echo "[vm-provision] $*"; }

# ── Host-protection guard ───────────────────────────────────────────────────
# This script mutates BTM (sfltool resetbtm), the TCC database
# (kTCCServiceAccessibility row insert), the developer group, and
# accepts the Xcode license — every one of which would be very wrong
# to run on the user's actual workstation. Refuse fast if anything
# suggests we're not inside the photox-e2e Tart VM. The checks are
# cheap and run before any sudo:
#
#   1. whoami must be `admin` (Cirrus image default user; matches
#      every /Users/admin/* path this script touches).
#   2. `sysctl kern.hv_vmm_present` must report 1 (Apple's canonical
#      "running under a hypervisor" flag — true under Tart's
#      Virtualization.framework, false on bare metal).
#   3. `hw.model` starts with `VirtualMac` (the VZ Apple Silicon
#      guest model identifier).
#
# If any check fails, abort with a clear message naming which signal
# was wrong so the user can debug.
WHO=$(whoami)
HV_PRESENT=$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)
HW_MODEL=$(sysctl -n hw.model 2>/dev/null || echo unknown)
if [[ ${WHO} != "admin" || ${HV_PRESENT} != "1" || ${HW_MODEL} != VirtualMac* ]]; then
    cat >&2 <<EOF
REFUSED: vm-provision.sh detected it is NOT running inside the
photox-e2e Tart VM. This script mutates system state (BTM, TCC,
developer group, Xcode license) that would be harmful on the host.

  whoami               = ${WHO}        (expected: admin)
  kern.hv_vmm_present  = ${HV_PRESENT} (expected: 1)
  hw.model             = ${HW_MODEL}   (expected: VirtualMac2,1 or similar)

If you reached this from \`just vm-up\` / \`just vm-e2e\` the VM
plumbing has misrouted the script — run \`just vm-shell\` to inspect.
EOF
    exit 99
fi

if [[ -f ${MARKER} ]]; then
    log "marker present (${MARKER}); already provisioned, nothing to do"
    exit 0
fi

log "starting (target: ${MARKER})"

# ── Xcode license + developer mode ──────────────────────────────────────────
# Both require sudo. The Cirrus image preconfigures admin with
# passwordless sudo via /etc/sudoers.d/admin (standard for Cirrus CI
# images), so no password prompt.
if ! sudo xcodebuild -license check >/dev/null 2>&1; then
    log "accepting Xcode license"
    sudo xcodebuild -license accept
fi

if ! /usr/sbin/DevToolsSecurity -status 2>&1 | grep -q "currently enabled"; then
    log "enabling DevToolsSecurity (lets non-admin run XCUITest)"
    sudo /usr/sbin/DevToolsSecurity -enable
fi

# Make sure admin is in the _developer group so it can drive Xcode
# without a separate prompt for the developer tools authorization
# right.
if ! dscl . -read /Groups/_developer GroupMembership 2>/dev/null \
        | tr ' ' '\n' | grep -qx admin; then
    log "adding admin to _developer group"
    sudo dseditgroup -o edit -a admin -t user _developer
fi

# ── Background Task Management reset ────────────────────────────────────────
# `CardWatcherSupervisor.bootstrapAtLaunch` (PhotoX/Util/
# CardWatcherSupervisor.swift:137) fires unconditionally — it's not
# gated on `LaunchFlags.uiTestMode`. Inside a fresh VM, the helper
# binary has no prior BTM record, so the first
# `SMAppService.agent(...).register()` raises a system approval banner
# ("PhotoX added items that can run in the background"). The banner is
# non-modal but can interfere with the accessibility hierarchy as it
# animates. `sfltool resetbtm` clears the per-bundle BTM cache so the
# first registration goes through without surfacing UI.
#
# Wrapped in `timeout 30` because empirically `sfltool resetbtm` can
# block indefinitely on a freshly-cloned Tart VM whose BTM daemon
# hasn't fully come up — observed 3+ hours of hang under macOS Tahoe
# on the Cirrus image. Best-effort: if the timeout trips, the cure is
# worse than the disease and we proceed without it; the CardWatcher
# banner is non-modal so tests will still pass even when present.
log "clearing Background Task Management cache (sfltool resetbtm, 30 s ceiling)"
sudo /usr/bin/timeout 30 sfltool resetbtm >/dev/null 2>&1 || \
    log "  sfltool resetbtm skipped (timeout or failure — see comment in vm-provision.sh)"

# ── Accessibility grant for XCUITest test runner ────────────────────────────
# XCUITest sends synthesized key / pointer events through
# AXUIElement, which requires the test runner (xctest /
# com.apple.dt.xctest.tool) to hold the Accessibility TCC permission.
# On a real human workstation this is granted via a System Settings
# click-through after the first prompt. The VM has no human to click,
# so we inject the rows directly.
#
# Safety justification for the TCC.db write: this VM exists solely to
# run our test suite, has no Apple ID signed in, no iCloud, no user
# secrets, and is rebuilt from a stock Cirrus image whenever the
# upstream image updates. The blast radius is "tests run". On a host
# Mac this script's TCC mutation would be unacceptable; here it's
# the only mechanism for non-interactive XCUITest.
log "granting Accessibility TCC permission to the Xcode test runner"
TCC_DB=/Library/Application\ Support/com.apple.TCC/TCC.db
# Insert rows for both legacy and modern bundle identifiers the
# test runner has used across Xcode generations. OR-ignore
# duplicates so the script is re-runnable.
for client in com.apple.dt.xctest.tool /Applications/Xcode.app/Contents/Developer/usr/bin/xctest; do
    sudo sqlite3 "${TCC_DB}" <<SQL || true
INSERT OR IGNORE INTO access (
    service, client, client_type, auth_value, auth_reason, auth_version,
    csreq, policy_id, indirect_object_identifier_type,
    indirect_object_identifier, indirect_object_code_identity, flags, last_modified
) VALUES (
    'kTCCServiceAccessibility', '${client}', 0, 2, 4, 1,
    NULL, NULL, 0,
    'UNUSED', NULL, 0, strftime('%s', 'now')
);
SQL
done

# ── SSH key install ─────────────────────────────────────────────────────────
# The host generates a per-VM ed25519 keypair at
# build/vm/id_ed25519{,.pub} on first ensure-provisioned, and uses
# `tart exec -i bash -c 'cat > $PUBKEY_INBOX'` to upload the pubkey
# BEFORE invoking this script. We just mirror it into authorized_keys.
# Key auth is the primary transport for ssh-rsync (artifacts + sample
# fixture) and `just vm-shell`.
mkdir -p /Users/admin/.ssh
chmod 700 /Users/admin/.ssh
touch /Users/admin/.ssh/authorized_keys
chmod 600 /Users/admin/.ssh/authorized_keys
if [[ -f ${PUBKEY_INBOX} ]]; then
    log "installing host pubkey from ${PUBKEY_INBOX}"
    cat "${PUBKEY_INBOX}" >> /Users/admin/.ssh/authorized_keys
    sort -u /Users/admin/.ssh/authorized_keys \
         -o /Users/admin/.ssh/authorized_keys
else
    log "WARN: ${PUBKEY_INBOX} not present — ssh-rsync transport will need password auth"
fi

# ── Marker ──────────────────────────────────────────────────────────────────
touch "${MARKER}"
log "provisioning complete (marker: ${MARKER})"
