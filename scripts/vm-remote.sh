#!/bin/bash
# vm-remote.sh — drive a Tart-managed macOS VM as a pure XCUITest
# runner. Build happens on the HOST; the VM receives a prebuilt
# .app + PhotoXUITests-Runner.app + .xctestrun + sample/ and runs
# `xcodebuild test-without-building`. The VM has its own
# WindowServer, so the host cursor / focus / windows are never
# touched. Hermetic to this repo: every bit of state lives under
# build/vm/ and never modifies host global state. No sudo.
#
# Lifecycle: suspend after every run. Next run resumes (~7 s). Cold
# boot (~20 s) only after `tart pull` / `tart delete` / a macOS
# update that invalidates the snapshot.
#
# Transport: ssh-rsync as the single path. The host generates a
# per-VM ed25519 keypair at build/vm/id_ed25519{,.pub} on first
# provisioning; the pubkey is mirrored into the VM's
# authorized_keys.
#
# Justfile vm-* recipes are thin wrappers around the subcommands
# below. See `Justfile` (vm-e2e, vm-up, vm-down, vm-shell, vm-clean,
# vm-pull, vm-build, vm-test, vm-status) for the user-facing entry
# points.
#
# Error contract: on any unrecoverable failure this script writes
# `ERROR: <tag>` to stderr followed by a one-line hint, then exits
# non-zero. Callers (and Claude Code) match on the tag.
set -euo pipefail

# Always work from the repo root so all relative paths resolve the
# same regardless of where the script is invoked from.
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# ── Tunables ────────────────────────────────────────────────────────────────

VM_NAME=photox-e2e
# Tahoe (macOS 26) Xcode-preinstalled image. :latest is intentional —
# we want auto-pickup of new Xcode releases. ensure-image detects
# when upstream changes and recreates the VM accordingly. ~80 GB
# sparse.
IMAGE=ghcr.io/cirruslabs/macos-tahoe-xcode:latest
# Cirrus image default. VM-internal-only credential — the VM has no
# externally-reachable surface beyond the host's network namespace.
VM_USER="admin"
VM_PASS="admin"

# Inside-VM layout. The VM is a pure XCUITest runner: it gets
# shipped artifacts under test-artifacts and the sample fixture
# under photox-fixtures. Neither survives a vm-pull (image refresh),
# both survive a vm-clean.
VM_ARTIFACTS=/Users/${VM_USER}/test-artifacts
VM_FIXTURES=/Users/${VM_USER}/photox-fixtures
VM_HOME=/Users/${VM_USER}

# Host-side state. Under build/ so it's already gitignored.
VM_STATE_DIR=build/vm
VM_RUN_LOG="${VM_STATE_DIR}/run.log"
VM_PID_FILE="${VM_STATE_DIR}/tart.pid"
# Snapshot of `tart list --source oci --format json` for $IMAGE,
# taken right after a successful ensure-image. Compared against
# VM_IMAGE_STATE_FILE on every ensure-vm; if different, the VM is
# recreated.
IMAGE_STATE_FILE="${VM_STATE_DIR}/image-state.json"
VM_IMAGE_STATE_FILE="${VM_STATE_DIR}/vm-image-state.json"
# Cached host-side sample/ dir mtime. Used by ensure-fixtures to
# decide whether to re-rsync.
SAMPLE_MTIME_FILE="${VM_STATE_DIR}/sample-mtime"
# Per-VM SSH keypair. Generated on first ensure-provisioned, mirrored
# into the VM's authorized_keys by vm-provision.sh.
SSH_KEY="${VM_STATE_DIR}/id_ed25519"
SSH_PUBKEY="${VM_STATE_DIR}/id_ed25519.pub"
# Host-side DerivedData for vm-e2e's build-for-testing step.
# Isolated from the user's interactive `just dev` cache so the two
# can run concurrently without trashing each other's incremental
# state.
HOST_DD="${VM_STATE_DIR}/dd"
HOST_PRODUCTS="${HOST_DD}/Build/Products"
HOST_PRODUCTS_DEBUG="${HOST_PRODUCTS}/Debug"
# Last-run summary read by vm-status.
LAST_RUN_FILE="${VM_STATE_DIR}/last-run.json"
# xcresult landing zone on host (after pull).
E2E_RESULTS_DIR=build/e2e-results

mkdir -p "${VM_STATE_DIR}" "${E2E_RESULTS_DIR}"

# ── Helpers ─────────────────────────────────────────────────────────────────

die() {
    local tag=$1; shift
    echo "ERROR: ${tag}" >&2
    if [[ $# -gt 0 ]]; then
        echo "$*" >&2
    fi
    exit 1
}

log() { echo "[vm-remote] $*"; }

run_with_log() {
    "$@" 2>&1 | tee -a "${VM_RUN_LOG}"
    return "${PIPESTATUS[0]}"
}

# `tart list --source oci` entry for $IMAGE — used as the digest
# proxy. `Accessed` shifts every time `tart list` runs, so we strip
# it; only the immutable identity fields (Name, Size, Disk) matter
# for "did upstream change since we cloned the VM."
image_state() {
    tart list --source oci --format json 2>/dev/null \
        | jq -c --arg img "${IMAGE}" \
            'map(select(.Name == $img)) | .[0] // empty
             | {Name, Size, Disk}' \
        || true
}

vm_exists() {
    tart list --source local --format json 2>/dev/null \
        | jq -e --arg name "${VM_NAME}" \
            'map(.Name) | index($name) != null' \
        > /dev/null
}

# Returns "running", "suspended", or "stopped". On any unexpected
# state defaults to "stopped" so the caller cold-boots.
vm_state() {
    local state
    state=$(tart list --source local --format json 2>/dev/null \
        | jq -r --arg name "${VM_NAME}" \
            'map(select(.Name == $name)) | .[0].State // "stopped"')
    case "${state}" in
        running|suspended|stopped) echo "${state}" ;;
        *) echo "stopped" ;;
    esac
}

# Returns 0 iff the VM is running AND tart-guest-agent answers.
vm_alive() {
    [[ -f "${VM_PID_FILE}" ]] || return 1
    local pid
    pid=$(cat "${VM_PID_FILE}")
    kill -0 "${pid}" 2>/dev/null || return 1
    tart ip --resolver agent --wait 2 "${VM_NAME}" >/dev/null 2>&1
}

vm_ip() {
    tart ip --resolver agent --wait 30 "${VM_NAME}" 2>/dev/null \
        || die vm-unreachable "tart-guest-agent did not respond within 30 s — try \`just vm-down && just vm-up\`"
}

# tart exec wrappers. Neither passes `-t` (allocate PTY) — Tart
# 2.32 crashes with a `try!` panic in tart/Exec.swift:100
# ("failed to get terminal size: Inappropriate ioctl for device")
# when `-t` is requested but the caller's stdout is a pipe, which
# is true for every call site here (we either capture stdout into
# a variable or pipe it into `tar -xf -`). We don't need a PTY for
# any of these — they're scripted, no interactivity. Interactive
# debug shells go through `cmd_shell` over plain SSH.
#
# `vm_exec` retains `-i` for callers that stream stdin (the
# provisioner script, `tar -cf -` source streams). `vm_exec_no_stdin`
# omits `-i` for callers whose command provides all its own input.
vm_exec() {
    tart exec -i "${VM_NAME}" "$@"
}

vm_exec_no_stdin() {
    tart exec "${VM_NAME}" "$@"
}

# ssh-rsync transport. SSH options keep host-key churn out of the
# user's known_hosts; ControlMaster amortizes the handshake across
# multiple rsync invocations in a single run.
SSH_OPTS=(
    -i "${SSH_KEY}"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ControlMaster=auto
    -o ControlPath="/tmp/ssh-photox-%r@%h:%p"
    -o ControlPersist=60
)

# Run ssh into the VM with our key. $@ is the remote command (or
# empty for an interactive shell). VM IP is resolved via Guest Agent.
vm_ssh() {
    local ip
    ip=$(vm_ip)
    ssh "${SSH_OPTS[@]}" "${VM_USER}@${ip}" "$@"
}

# rsync $1 → admin@<vm-ip>:$2. $3+ are extra rsync flags.
vm_rsync_to() {
    local src=$1; shift
    local dest=$1; shift
    local ip
    ip=$(vm_ip)
    rsync -aW --delete "$@" \
        -e "ssh ${SSH_OPTS[*]}" \
        "${src}" "${VM_USER}@${ip}:${dest}"
}

# Used by cmd_ensure_provisioned to upload the pubkey BEFORE
# provisioning runs (key auth isn't available yet, so this goes
# over `tart exec` stdin).
upload_pubkey_via_tart_exec() {
    [[ -f "${SSH_PUBKEY}" ]] || die provision-failed "missing ${SSH_PUBKEY}; was the key generated?"
    vm_exec bash -c 'mkdir -p /tmp/photox-bootstrap && cat > /tmp/photox-bootstrap/host-pubkey' \
        < "${SSH_PUBKEY}"
}

# Generate the per-VM SSH keypair on first call. Idempotent.
ensure_ssh_key() {
    if [[ -f "${SSH_KEY}" && -f "${SSH_PUBKEY}" ]]; then
        return 0
    fi
    log "generating per-VM SSH keypair (${SSH_KEY})"
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N '' -C "photox-e2e@$(hostname -s)" -q
}

# Expected GitDescribe string — used at build time as a build-setting
# override AND at post-ship/post-run time as the ground truth for
# `_verify_shipment` and `_verify_runtime_version`. Cached after the
# first call (`EXPECTED_GIT_DESCRIBE`) so the build invocation and
# the two verify gates see the SAME value within one dispatcher run.
#
# Dirty trees get a `-dirty-HHMMSS` suffix (local time) so back-to-
# back test cycles with no intermediate commit still produce
# distinguishable build identities in logs and on disk. A clean HEAD
# just gets the 9-char sha. Matches `just dev`'s derivation aside
# from the timestamp suffix (dev launches don't need the
# disambiguator).
EXPECTED_GIT_DESCRIBE=""
expected_git_describe() {
    if [[ -z "${EXPECTED_GIT_DESCRIBE}" ]]; then
        local sha9 suffix=""
        sha9=$(git rev-parse --short=9 HEAD)
        if [[ -n "$(git status --porcelain)" ]]; then
            suffix="-dirty-$(date +%H%M%S)"
        fi
        EXPECTED_GIT_DESCRIBE="v0.0.0-dev-${sha9}${suffix}"
    fi
    printf '%s' "${EXPECTED_GIT_DESCRIBE}"
}

# Git-derived version strings, matching `just dev`'s logic exactly
# so vm-e2e and just dev produce binaries with consistent identity.
git_describe_args() {
    printf 'MARKETING_VERSION=0.0.0 CURRENT_PROJECT_VERSION=0 GIT_DESCRIBE=%s' \
        "$(expected_git_describe)"
}

# POSTHOG_API_KEY override, same as Justfile's _posthog_key.
posthog_key_arg() {
    local key=""
    if [[ -n "${POSTHOG_API_KEY:-}" ]]; then
        key="${POSTHOG_API_KEY}"
    elif [[ -f scripts/release.local.env ]]; then
        key=$(grep -E '^POSTHOG_API_KEY=' scripts/release.local.env \
              | head -1 | cut -d= -f2- | tr -d '"' || true)
    fi
    printf 'POSTHOG_API_KEY=%s' "${key}"
}

# ── Subcommands ─────────────────────────────────────────────────────────────

cmd_ensure_image() {
    log "pulling ${IMAGE} (cheap if unchanged)…"
    if ! run_with_log tart pull "${IMAGE}"; then
        die image-pull-failed "tart pull failed — check ghcr.io connectivity and disk space"
    fi
    image_state > "${IMAGE_STATE_FILE}"
    if [[ ! -s "${IMAGE_STATE_FILE}" ]]; then
        die image-pull-failed "tart list did not surface ${IMAGE} after pull (unexpected)"
    fi
    log "image state cached: ${IMAGE_STATE_FILE}"
}

cmd_ensure_vm() {
    [[ -s "${IMAGE_STATE_FILE}" ]] || cmd_ensure_image

    local need_recreate=0
    if ! vm_exists; then
        log "VM ${VM_NAME} not present — will clone from image"
        need_recreate=1
    elif [[ ! -s "${VM_IMAGE_STATE_FILE}" ]]; then
        log "VM ${VM_NAME} exists but image-state-of-record is missing — recreating"
        need_recreate=1
    elif ! cmp -s "${IMAGE_STATE_FILE}" "${VM_IMAGE_STATE_FILE}"; then
        log "upstream image updated — recreating VM (~30 s clone + ~30 s provision catch-up)"
        need_recreate=1
    fi

    if [[ ${need_recreate} -eq 1 ]]; then
        if vm_exists; then
            cmd_down >/dev/null 2>&1 || true
            run_with_log tart delete "${VM_NAME}" \
                || die vm-recreate-failed "tart delete ${VM_NAME} failed"
        fi
        run_with_log tart clone "${IMAGE}" "${VM_NAME}" \
            || die vm-recreate-failed "tart clone ${IMAGE} → ${VM_NAME} failed"
        cp "${IMAGE_STATE_FILE}" "${VM_IMAGE_STATE_FILE}"
        log "VM ${VM_NAME} freshly cloned from ${IMAGE}"
    fi
}

# Spawn `tart run --suspendable`. Records the log line count at
# launch time so the caller's VZErrorDomain 12 detector only sees
# errors from THIS spawn (not stale errors from prior session).
# Caller reads the cursor from `${VM_RUN_LOG}.cursor`.
_tart_run_suspendable() {
    rm -f "${VM_PID_FILE}"
    # Mark the spawn boundary so VZErrorDomain probes look only at
    # log lines added after this point.
    wc -l < "${VM_RUN_LOG}" 2>/dev/null | tr -d ' ' \
        > "${VM_RUN_LOG}.cursor" \
        || echo 0 > "${VM_RUN_LOG}.cursor"
    nohup tart run --no-graphics --no-audio --no-clipboard --suspendable \
        "${VM_NAME}" >> "${VM_RUN_LOG}" 2>&1 &
    echo $! > "${VM_PID_FILE}"
}

cmd_ensure_running() {
    if vm_alive; then
        return 0
    fi

    local state
    state=$(vm_state)
    if [[ "${state}" == "suspended" ]]; then
        log "resuming VM ${VM_NAME} from suspend (~7 s)…"
    elif [[ "${state}" == "running" ]]; then
        # `tart list` says running but our agent probe failed — stale
        # tart process or orphan. Force-clean and cold-boot.
        log "VM ${VM_NAME} reports running but agent unreachable — clearing"
        tart stop "${VM_NAME}" 2>/dev/null || true
        log "starting VM ${VM_NAME} (cold, ~20 s)…"
    else
        log "starting VM ${VM_NAME} (cold, ~20 s)…"
    fi

    _tart_run_suspendable

    # Poll for Guest Agent readiness. Two distinct error signatures
    # in run.log warrant immediate recovery instead of waiting out
    # the 90 s deadline:
    #
    #   - VZErrorDomain Code=12 ("invalid argument" at restore) —
    #     the suspend snapshot is corrupted. Recovery: full cleanup
    #     + cold-boot.
    #   - VZErrorDomain Code=2 ("Failed to lock auxiliary storage"
    #     with NSPOSIXErrorDomain Code=35 / EAGAIN) — the previous
    #     tart-run's flock on aux storage hasn't released yet.
    #     cmd_suspend now waits for it, but if a stragglerstill slips
    #     through (or a tart instance from another process holds the
    #     lock), the previous `tart run` has already exited so there
    #     is nothing to kill. Recovery: brief sleep + re-spawn the
    #     same `tart run` — the resume from suspend then proceeds
    #     normally.
    #
    # The cursor stored by _tart_run_suspendable bounds the grep to
    # THIS spawn's log lines (otherwise we'd match stale errors from
    # prior sessions and loop forever).
    local deadline=$((SECONDS + 90))
    local recovered=0
    while (( SECONDS < deadline )); do
        if tart ip --resolver agent --wait 2 "${VM_NAME}" >/dev/null 2>&1; then
            log "VM ${VM_NAME} is up"
            return 0
        fi
        local cursor
        cursor=$(cat "${VM_RUN_LOG}.cursor" 2>/dev/null || echo 0)
        local recent
        recent=$(tail -n "+$((cursor + 1))" "${VM_RUN_LOG}" 2>/dev/null || true)
        if (( recovered == 0 )); then
            if echo "${recent}" | grep -q "VZErrorDomain Code=12"; then
                recovered=1
                log "suspend snapshot is corrupted (VZ Code=12) — falling back to cold-boot"
                local pid
                pid=$(cat "${VM_PID_FILE}" 2>/dev/null || echo 0)
                kill "${pid}" 2>/dev/null || true
                sleep 1
                tart stop "${VM_NAME}" 2>/dev/null || true
                _tart_run_suspendable
                deadline=$((SECONDS + 90))
            elif echo "${recent}" | grep -q "VZErrorDomain Code=2"; then
                recovered=1
                log "aux-storage lock contention (VZ Code=2) — sleeping 3 s, re-spawning tart run"
                rm -f "${VM_PID_FILE}"
                sleep 3
                _tart_run_suspendable
                deadline=$((SECONDS + 90))
            fi
        fi
        sleep 2
    done
    # First 90 s timed out without a VZError-12 marker. Observed
    # in practice: back-to-back stability runs hit a silent
    # tart-guest-agent unresponsiveness on resume-from-suspend,
    # roughly every other invocation, with no log signature to
    # trigger the recovery path above. Try one cold-boot before
    # dying — that's cheap (~20-30 s when it works) and converts
    # a hard fail into a recoverable hiccup.
    if (( recovered == 0 )); then
        log "agent unresponsive after 90 s — falling back to cold-boot"
        local pid2
        pid2=$(cat "${VM_PID_FILE}" 2>/dev/null || echo 0)
        kill "${pid2}" 2>/dev/null || true
        sleep 1
        tart stop "${VM_NAME}" 2>/dev/null || true
        _tart_run_suspendable
        deadline=$((SECONDS + 120))
        while (( SECONDS < deadline )); do
            if tart ip --resolver agent --wait 2 "${VM_NAME}" >/dev/null 2>&1; then
                log "VM ${VM_NAME} is up (after cold-boot recovery)"
                return 0
            fi
            sleep 2
        done
    fi
    die vm-unreachable "VM started but tart-guest-agent never responded — check ${VM_RUN_LOG}"
}

cmd_ensure_provisioned() {
    cmd_ensure_running
    ensure_ssh_key
    if vm_exec test -f "${VM_HOME}/.photox-vm-provisioned" 2>/dev/null; then
        return 0
    fi
    log "first-run provisioning (~30 s)…"
    upload_pubkey_via_tart_exec
    if ! vm_exec bash -s -- < "${REPO_ROOT}/scripts/vm-provision.sh"; then
        die provision-failed "vm-provision.sh failed inside ${VM_NAME} — see stderr above"
    fi
    log "provisioning complete"
}

# Stamp PhotoX.app and the embedded PhotoXCardWatcher.app Info.plists
# with the expected GitDescribe, then ad-hoc re-sign. xcodebuild's
# incremental cache doesn't track command-line build-setting
# overrides as inputs, so a dirty-tree rebuild with no source change
# will keep the GitDescribe from a prior run. Post-processing forces
# the running binary's `Bundle.main.object(forInfoDictionaryKey:
# "GitDescribe")` to read the value we expect, which lets
# `_verify_shipment` and `_verify_runtime_version` enforce exact
# match.
#
# Order matters: re-sign the embedded helper FIRST, then the parent
# app, so the parent's seal includes the helper's new content hash.
_stamp_bundles() {
    local expected app helper
    expected=$(expected_git_describe)
    app="${HOST_PRODUCTS_DEBUG}/PhotoX.app"
    helper="${app}/Contents/Library/LoginItems/PhotoXCardWatcher.app"

    for bundle in "${helper}" "${app}"; do
        local plist="${bundle}/Contents/Info.plist"
        [[ -f "${plist}" ]] || continue
        plutil -replace GitDescribe -string "${expected}" "${plist}"
        # Ad-hoc re-sign. `--preserve-metadata=entitlements,flags` keeps
        # the entitlements from the original signing so we don't strip
        # `com.apple.security.cs.disable-library-validation` and the
        # hardened-runtime-off flag. Errors are non-fatal (Debug builds
        # are happy to launch with imperfect signatures).
        codesign --force --sign - \
            --preserve-metadata=entitlements,flags \
            "${bundle}" >/dev/null 2>&1 || true
    done
}

# Run xcodebuild build-for-testing on the host with an isolated
# DerivedData. Mirrors the version overrides used by `just dev` so
# the binary's About panel still reads like a real dev build.
cmd_host_build() {
    cmd_ensure_provisioned
    # Prime EXPECTED_GIT_DESCRIBE in the parent shell. Otherwise the
    # first call happens inside `$(git_describe_args)` (a subshell)
    # for the xcodebuild override, the cache lives only in that
    # subshell, and `_stamp_bundles` / `_verify_shipment` re-compute
    # a fresh HHMMSS — landing 1+ s later and tripping the gate.
    expected_git_describe >/dev/null
    log "host build-for-testing → ${HOST_DD} (isolated from \`just dev\`'s cache)…"
    # shellcheck disable=SC2046
    if ! xcodebuild build-for-testing \
            -scheme PhotoX -configuration Debug \
            -destination 'platform=macOS' \
            -derivedDataPath "${HOST_DD}" \
            CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
            $(git_describe_args) \
            "$(posthog_key_arg)" \
            -quiet 2>&1 | tee -a "${VM_RUN_LOG}"; then
        die host-build-failed "host xcodebuild build-for-testing failed — full log at ${VM_RUN_LOG}"
    fi
    _stamp_bundles
    log "host build complete (stamped @ $(expected_git_describe))"
}

# Find the xctestrun that build-for-testing emitted. Newer Xcode names
# it Debug_macOS.xctestrun; older was Debug.xctestrun. Pick the
# newest match.
_find_xctestrun() {
    # shellcheck disable=SC2012
    ls -1t "${HOST_PRODUCTS}"/*.xctestrun 2>/dev/null | head -1
}

# Patch the xctestrun's per-target EnvironmentVariables so the
# prebuilt test bundle's `PhotoXUITestCase.repoSampleURL` resolves
# to the VM's local fixture path instead of the host's compile-time
# #file walk, and drop the PhotoXTests (unit) target entirely.
#
# Why strip PhotoXTests: it's an IsAppHostedTestBundle with RunOrder=0,
# so xcodebuild test-without-building tries to load it before
# PhotoXUITests. The bundle never successfully injects in the VM
# (xcresults show PhotoXTests.xctest is never opened — even on warm
# runs the test summary only lists PhotoXUITests entries), and the
# attempt costs a ~5 min xctest bundle-load timeout on cold/long-
# suspended VMs (10:05 wall → 4:51 once dropped). Unit tests still
# run on the host via `just test`. See docs/runner-attach-diag.md.
_patch_xctestrun_env() {
    local src=$1
    local patched
    patched="$(dirname "${src}")/.patched-$(basename "${src}")"
    cp "${src}" "${patched}"

    # The xctestrun's top-level keys are the BlueprintNames of the
    # test targets. We only need PhotoXUITests to see the env var.
    local target=PhotoXUITests
    local env_path="${target}.EnvironmentVariables.PHOTOX_FIXTURE_SOURCE_DIR"
    local value="${VM_FIXTURES}/sample"

    # `-replace` if the key already exists, otherwise `-insert`.
    if plutil -extract "${env_path}" raw "${patched}" >/dev/null 2>&1; then
        plutil -replace "${env_path}" -string "${value}" "${patched}"
    else
        # Need to make sure EnvironmentVariables itself exists.
        if ! plutil -extract "${target}.EnvironmentVariables" raw "${patched}" >/dev/null 2>&1; then
            plutil -insert "${target}.EnvironmentVariables" -dictionary "${patched}"
        fi
        plutil -insert "${env_path}" -string "${value}" "${patched}"
    fi

    # Drop PhotoXTests so xcodebuild won't attempt the doomed unit-
    # test phase. Safe to no-op if the key was already removed
    # upstream (some Xcode versions may emit a UI-only xctestrun).
    plutil -remove PhotoXTests "${patched}" 2>/dev/null || true

    # --record: switch the test target's automatic-attachment
    # lifetimes from `deleteOnSuccess` (the host build default) to
    # `keepAlways`. The xctestrun already has
    # `PreferredScreenCaptureFormat = screenRecording`, so this
    # makes the automatic screen recording persist for every test,
    # not just failures. Useful for "show me what each test does"
    # review passes; not on by default because the recordings
    # balloon xcresult size by ~hundreds of MB on a full suite.
    if [[ "${PHOTOX_E2E_RECORD_ALL:-0}" == "1" ]]; then
        plutil -replace "${target}.UserAttachmentLifetime" \
            -string "keepAlways" "${patched}" 2>/dev/null || true
        plutil -replace "${target}.SystemAttachmentLifetime" \
            -string "keepAlways" "${patched}" 2>/dev/null || true
    fi

    printf '%s' "${patched}"
}

# Ship artifacts (PhotoX.app, PhotoXUITests-Runner.app, .xctestrun)
# from the host's isolated DerivedData into the VM's
# ~admin/test-artifacts/. ssh-rsync delta-transfers, so a small
# code change typically sends just the relinked binary segments.
_ship_artifacts() {
    local xctestrun_src
    xctestrun_src=$(_find_xctestrun)
    [[ -n "${xctestrun_src}" ]] || die ship-failed "no .xctestrun produced — host build did not emit a test plan"

    log "shipping artifacts → ${VM_NAME}:${VM_ARTIFACTS}/ (ssh-rsync delta)…"
    # xctestrun references bundles relative to __TESTROOT__ (the
    # xctestrun's own directory) plus the original build folder
    # layout — concretely `Debug/<bundle>.app`. Mirror that here:
    # xctestrun at ${VM_ARTIFACTS}/, bundles under ${VM_ARTIFACTS}/Debug/.
    vm_ssh "mkdir -p '${VM_ARTIFACTS}/Debug'"

    local apps=()
    for app in "${HOST_PRODUCTS_DEBUG}"/*.app; do
        [[ -d "${app}" ]] && apps+=("${app}")
    done
    if [[ ${#apps[@]} -eq 0 ]]; then
        die ship-failed "no .app bundles in ${HOST_PRODUCTS_DEBUG}/"
    fi
    for app in "${apps[@]}"; do
        vm_rsync_to "${app}/" "${VM_ARTIFACTS}/Debug/$(basename "${app}")/" \
            || die ship-failed "rsync of $(basename "${app}") failed"
    done
    # Patch the xctestrun to inject PHOTOX_FIXTURE_SOURCE_DIR, then
    # ship the patched copy under the original filename (so
    # test-without-building uses the patched one).
    local xctestrun_patched
    xctestrun_patched=$(_patch_xctestrun_env "${xctestrun_src}")
    vm_rsync_to "${xctestrun_patched}" "${VM_ARTIFACTS}/$(basename "${xctestrun_src}")" \
        || die ship-failed "rsync of $(basename "${xctestrun_src}") failed"
    log "shipped: ${#apps[@]} bundle(s) + $(basename "${xctestrun_src}")"
}

# Sample fixture sync. Only re-rsync when host sample/ mtime changes
# (the fixture is rarely edited).
_ship_fixtures() {
    local host_mtime cached_mtime=0
    host_mtime=$(stat -f %m "${REPO_ROOT}/sample" 2>/dev/null || echo 0)
    [[ -f "${SAMPLE_MTIME_FILE}" ]] && cached_mtime=$(cat "${SAMPLE_MTIME_FILE}")

    if [[ "${host_mtime}" == "${cached_mtime}" ]] \
        && vm_ssh "test -d '${VM_FIXTURES}/sample'" 2>/dev/null; then
        return 0
    fi
    if [[ ! -d "${REPO_ROOT}/sample" ]]; then
        die ship-failed "host sample/ directory missing at ${REPO_ROOT}/sample — XCUITest needs the fixture"
    fi

    log "shipping fixture → ${VM_NAME}:${VM_FIXTURES}/sample/ (~3.7 GB on first sync; mtime-cached after)…"
    vm_ssh "mkdir -p '${VM_FIXTURES}'"
    vm_rsync_to "${REPO_ROOT}/sample/" "${VM_FIXTURES}/sample/" \
        || die ship-failed "fixture rsync failed"
    echo "${host_mtime}" > "${SAMPLE_MTIME_FILE}"
    log "fixture sync complete"
}

# Read GitDescribe from a bundle's Info.plist in the VM. Empty string
# if absent (bundle missing or key not set).
_vm_bundle_git_describe() {
    local plist=$1
    vm_ssh "plutil -extract GitDescribe raw '${plist}' 2>/dev/null || true"
}

# Verify the bundles we just shipped advertise the GitDescribe we
# expect. Catches: rsync didn't actually update the files (stale
# bundle), wrong xcodebuild override propagation, accidental shipment
# from a different build path, and so on. Also checks the embedded
# PhotoXCardWatcher.app — the supervisor in PhotoX bounces the
# helper to the canonical in-bundle path on every launch, so as
# long as the bundled helper is current the running one will be too.
_verify_shipment() {
    local expected
    expected=$(expected_git_describe)
    local app_plist="${VM_ARTIFACTS}/Debug/PhotoX.app/Contents/Info.plist"
    local helper_plist="${VM_ARTIFACTS}/Debug/PhotoX.app/Contents/Library/LoginItems/PhotoXCardWatcher.app/Contents/Info.plist"
    local app_got helper_got
    app_got=$(_vm_bundle_git_describe "${app_plist}" | tr -d '[:space:]')
    helper_got=$(_vm_bundle_git_describe "${helper_plist}" | tr -d '[:space:]')

    if [[ "${app_got}" != "${expected}" ]]; then
        die ship-failed "PhotoX.app GitDescribe mismatch: got '${app_got}', expected '${expected}'"
    fi
    if [[ "${helper_got}" != "${expected}" ]]; then
        die ship-failed "PhotoXCardWatcher.app GitDescribe mismatch: got '${helper_got}', expected '${expected}'"
    fi
    log "shipment verified: PhotoX + PhotoXCardWatcher @ ${expected}"
}

# Suppress system-level notification banners inside the VM so they
# don't pollute XCUITest screenshots and screen recordings. The
# main offender on our Tahoe image is macOS's BTM banner for
# "tart-guest-agent" (Cirrus's Guest Agent triggers it whenever it
# touches background activity), but the same machinery hides the
# CardWatcher SMAppService approval banner and any future helpers
# Apple decides to advertise.
#
# Approach: unload NotificationCenter's launchd job entirely so it
# cannot respawn and re-render the banner. Lighter-weight tries
# (`killall NotificationCenter`, sqlite-delete on usernoted's DB,
# `sfltool resetbtm`) all leave the banner sticky because BTM's
# "notified" disposition flag persists across the kill/respawn
# cycle in macOS Tahoe (verified empirically: `sfltool dumpbtm`
# shows `Disposition: [enabled, allowed, notified]` for
# tart-guest-agent and the banner reappears within ~1 s of any
# attempt to clear it short of unload).
#
# `launchctl bootout` requires the GUI session domain so we resolve
# the admin user's UID first. After unload, NotificationCenter
# cannot show banners until either the next reboot or an explicit
# `bootstrap`. We rely on the next VM resume (after `tart suspend`)
# to bring it back; the suspend snapshot captures the post-bootout
# state, so subsequent runs inherit it for free.
_dismiss_system_banners() {
    log "unloading NotificationCenter (prevents BTM banner from rendering during tests)…"
    vm_ssh '
        UID_VAL=$(id -u)
        ROOT_NC=/System/Library/LaunchAgents/com.apple.notificationcenterui.plist
        echo admin | sudo -S launchctl bootout gui/${UID_VAL} ${ROOT_NC} 2>/dev/null || true
        killall NotificationCenter 2>/dev/null || true
        true
    '
}

# Headline ship: build on host, ship artifacts, ship fixtures, verify.
cmd_ship() {
    cmd_host_build
    _ship_artifacts
    _ship_fixtures
    _verify_shipment
}

# Read the env var override for the test runner so PhotoXUITestCase's
# repoSampleURL resolves to the VM's fixture path instead of the
# host's compile-time #file walk-up.
_test_env_args() {
    printf 'PHOTOX_FIXTURE_SOURCE_DIR=%s/sample' "${VM_FIXTURES}"
}

# In-VM test runner. Runs the caller's filter(s), or the full UI
# suite if none. PhotoXTests (unit) is stripped from the patched
# xctestrun upstream (see `_patch_xctestrun_env`), so even the
# unfiltered case only touches PhotoXUITests.
cmd_run() {
    # Track upstream image on every run. The cached state-file +
    # digest-cmp path in `cmd_ensure_vm` recreates the VM when
    # upstream changes; when it hasn't, this is a cheap manifest
    # HEAD. No timeout — a real Xcode bump can be many GB and we
    # don't want to cut a legitimate download short. Offline modes
    # (DNS / TCP reset) fail quickly with an error, which the `|| log`
    # catches so the run proceeds against cached state.
    cmd_ensure_image \
        || log "WARN: tart pull failed — using cached image state"
    cmd_ensure_vm

    # Parse leading flags. Order matters: --rerun-failed populates
    # `$@` from the prior xcresult before we forward to cmd_ship +
    # the rest of the run; --keep-on-fail tweaks suspend behaviour;
    # --record bumps the xctestrun's attachment lifetime so the
    # automatic screen recording (xctestrun already sets
    # `PreferredScreenCaptureFormat = screenRecording`) is retained
    # for EVERY test, not just failures; --cold-boot stops the VM
    # before this run so cmd_ensure_running cold-boots instead of
    # resuming from suspend (diagnostic escape hatch when the
    # suspended state is suspect — the happy path is suspend-resume).
    local rerun_failed=0
    local keep_on_fail=0
    local cold_boot=0
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --rerun-failed) rerun_failed=1; shift ;;
            --keep-on-fail) keep_on_fail=1; shift ;;
            --record)       export PHOTOX_E2E_RECORD_ALL=1; shift ;;
            --cold-boot)    cold_boot=1; shift ;;
            --)             shift; break ;;
            *)              die usage "unknown flag: $1" ;;
        esac
    done
    if [[ "${PHOTOX_E2E_KEEP_ON_FAIL:-0}" == "1" ]]; then
        keep_on_fail=1
    fi
    if [[ "${PHOTOX_E2E_RECORD_ALL:-0}" == "1" ]]; then
        log "--record: xctestrun lifetimes will be patched to keepAlways (recordings retained for every test)"
    fi
    if (( cold_boot )); then
        log "--cold-boot: forcing tart stop so the next ensure_running cold-boots instead of resuming"
        # Kill the tart-run process (if any) and tell tart to stop.
        # Both are idempotent — already-stopped is the no-op case.
        if [[ -f "${VM_PID_FILE}" ]]; then
            local pid
            pid=$(cat "${VM_PID_FILE}" 2>/dev/null || echo 0)
            kill "${pid}" 2>/dev/null || true
            rm -f "${VM_PID_FILE}"
        fi
        tart stop "${VM_NAME}" 2>/dev/null || true
        # Give the kernel a moment to release any aux-storage flock
        # before cmd_ensure_running fires _tart_run_suspendable — same
        # rationale as the cmd_suspend settle in B1.
        sleep 1
    fi

    if (( rerun_failed )); then
        local rerun_args
        rerun_args=$(_collect_failing_test_ids \
            "${E2E_RESULTS_DIR}/latest/last.xcresult")
        if [[ -z "${rerun_args}" ]]; then
            log "no recent failures recorded — nothing to re-run"
            return 0
        fi
        log "--rerun-failed picked $(echo "${rerun_args}" | wc -w | tr -d ' ') test(s):"
        for id in ${rerun_args}; do log "  • ${id}"; done
        # Replace positional args so the rest of the function sees
        # them as if the caller typed each identifier explicitly.
        # shellcheck disable=SC2086 # word-split intentional: one $@ per test id
        set -- ${rerun_args} "$@"
    fi

    cmd_ship
    _dismiss_system_banners

    # Normalize each filter to a fully-qualified xcodebuild path so
    # callers can use shorthand. xcodebuild rejects a bare class name
    # without the bundle prefix ("SmokeTests" → "isn't a member of
    # the specified test plan or scheme"), and typing PhotoXUITests/
    # on every invocation is tedium for no benefit. The PhotoXUITests
    # bundle is the only XCUITest target in the scheme, so the prefix
    # is unambiguous. Multiple filters form a union — e.g.
    # `just vm-e2e RatingTests UndoTests` runs both classes.
    local filters=()
    for arg in "$@"; do
        case "${arg}" in
            PhotoXUITests/*|PhotoXUITests) filters+=("${arg}") ;;
            *)                             filters+=("PhotoXUITests/${arg}") ;;
        esac
    done

    # Stamp the test-run start (UTC). _collect_logs uses this to
    # bound `log show` to just the window the tests covered.
    RUN_START_TS=$(date -u +"%Y-%m-%d %H:%M:%S")
    export RUN_START_TS

    local xctestrun_name
    xctestrun_name=$(basename "$(_find_xctestrun)")
    local xctestrun_remote="${VM_ARTIFACTS}/${xctestrun_name}"
    # Pin xcresult to a known path inside test-artifacts/ so
    # cmd_pull_xcresult finds it deterministically instead of
    # scanning DerivedData (which can contain stale bundles from
    # the old in-VM-build architecture).
    local xcresult_remote="${VM_ARTIFACTS}/last.xcresult"

    # Build the in-VM xcodebuild command for one stage. $1 is a list
    # of -only-testing args (space-separated), $2 is a label.
    _run_stage() {
        local only_list=$1 label=$2
        log "in-VM: ${label}"
        local only_args=""
        for arg in ${only_list}; do
            only_args+=" -only-testing:${arg}"
        done
        # 600 s test cap matches host's `just e2e`. test-without-building
        # requires -destination (it builds nothing but still needs a
        # platform target). -resultBundlePath pins the xcresult so
        # cmd_pull_xcresult finds it deterministically.
        local cmd="cd '${VM_ARTIFACTS}' && rm -rf '${xcresult_remote}' && $(_test_env_args) timeout 600 xcodebuild test-without-building -xctestrun '${xctestrun_remote}' -destination 'platform=macOS' -resultBundlePath '${xcresult_remote}'${only_args}"
        # Filter xcodebuild's noisy bookend lines:
        #   - bare "Testing started" (printed twice — once before the
        #     first Test Suite header and once *after* TEST EXECUTE
        #     SUCCEEDED, with no useful content either time)
        #   - [MT] IDETestOperationsObserverDebug timing lines (Xcode
        #     internal stopwatch, duplicates what our summary table
        #     already shows)
        #
        # `sed` over `grep -v` because sed exits 0 on successful
        # processing regardless of whether any deletions matched, so
        # `set -o pipefail` cleanly forwards xcodebuild's real exit
        # code as the pipe's status. No `|| true` swallowing, no
        # explicit return needed.
        vm_exec_no_stdin bash -c "${cmd}" 2>&1 \
            | sed -E '/^Testing started$/d; /\[MT\] IDETestOperationsObserverDebug:/d'
    }

    # Caller's filter (or full UI suite if none).
    local rc=0
    if [[ ${#filters[@]} -eq 0 ]]; then
        _run_stage "" "full suite" || rc=$?
    else
        _run_stage "${filters[*]}" "${filters[*]}" || rc=$?
    fi

    cmd_pull_xcresult "${xcresult_remote}" || true
    if (( rc != 0 )); then
        _write_last_run "failed" "${rc}"
        _maybe_suspend "${rc}"
        die xcodebuild-failed "test run failed (exit ${rc}) — see ${E2E_RESULTS_DIR}/latest/"
    fi
    _write_last_run "passed" 0
    _maybe_suspend 0
    log "run completed cleanly"
}

# Collect macOS unified logs from the VM for the time window the
# tests ran in, save to ${dest_dir}/logs/photox.log on host. Window
# is bounded by ${RUN_START_TS} (UTC, set by cmd_run before the
# first test stage) and "now".
#
# Predicate is the OR of our two product subsystems:
# - `dev.frostman.PhotoX` — main app (Log.app, PerfTracker,
#   CardWatcherSupervisor, etc.).
# - `dev.frostman.PhotoX.CardWatcher` — the helper binary at
#   PhotoXCardWatcher/main.swift.
# Both lines that `_verify_runtime_version` greps for live under
# these subsystems (the main app's `PhotoX launching:
# GitDescribe=` and the helper's `startup. version=`).
#
# We deliberately do NOT use `BEGINSWITH "dev.frostman.PhotoX"` —
# that prefix also matches `dev.frostman.PhotoXUITests.xctrunner`
# (the UI runner) and would re-introduce a few hundred KB of
# runner noise we just got rid of. Likewise, we don't match on
# `processImagePath`: the earlier `processImagePath CONTAINS
# "PhotoX"` predicate produced 26 MB logs because
# XCTAutomationSupport is injected into the host PhotoX process
# and emits ~48k lines per full-suite run.
# `--info` keeps boot/teardown markers; `--debug` is dropped on
# the hot path since debug-level output for a passing test is
# rarely actionable.
_collect_logs() {
    local dest_dir=$1
    if [[ -z "${RUN_START_TS:-}" ]]; then
        log "log capture skipped (RUN_START_TS not set)"
        return 0
    fi
    mkdir -p "${dest_dir}/logs"

    # log show's predicate is NSPredicate syntax. Write the full
    # command to a remote script file via stdin instead of inlining
    # it in vm_ssh's arg — saves us from triple-level quote escaping
    # (host bash → ssh → remote bash → log).
    local script="${dest_dir}/logs/.fetch.sh"
    cat > "${script}" <<EOF
#!/bin/bash
log show --start '${RUN_START_TS}' \\
    --predicate 'subsystem == "dev.frostman.PhotoX" OR subsystem == "dev.frostman.PhotoX.CardWatcher"' \\
    --info
EOF
    chmod +x "${script}"

    # Pipe the script in as stdin to a remote bash; capture stdout.
    if ! vm_ssh "bash -s" < "${script}" \
            > "${dest_dir}/logs/photox.log" 2>"${dest_dir}/logs/photox.err"; then
        log "WARN: log show ssh transport failed; see ${dest_dir}/logs/photox.err"
    fi
    rm -f "${script}"
    local bytes
    bytes=$(wc -c < "${dest_dir}/logs/photox.log" 2>/dev/null | tr -d ' ' || echo 0)
    if (( bytes > 100 )); then
        log "captured VM logs: ${dest_dir}/logs/photox.log ($((bytes / 1024)) KiB)"
        rm -f "${dest_dir}/logs/photox.err"
    else
        # Keep the .err file for diagnostics; remove empty .log.
        if (( bytes == 0 )); then
            rm -f "${dest_dir}/logs/photox.log"
        fi
        log "WARN: log show captured ${bytes} bytes — predicate may have matched nothing"
    fi
}

# Pull the .xcresult bundle out of the VM and into the host's
# build/e2e-results/<ts>/ tree. Extracts screenshots, prints a
# failure summary if any tests failed, and captures unified logs
# from the test run's time window. $1 is the in-VM path to the
# xcresult; if omitted, scans DerivedData for the newest bundle
# (fallback for ad-hoc invocations).
cmd_pull_xcresult() {
    local stamp
    stamp=$(date +%Y%m%dT%H%M%S)
    local dest="${E2E_RESULTS_DIR}/${stamp}"
    mkdir -p "${dest}"

    local xcresult_path
    if [[ $# -gt 0 && -n "$1" ]]; then
        xcresult_path=$1
        # Sanity-check it exists in the VM.
        if ! vm_ssh "test -d '${xcresult_path}'" 2>/dev/null; then
            log "no .xcresult at ${xcresult_path} inside VM"
            return 1
        fi
    else
        local find_cmd="find ${VM_HOME}/Library/Developer/Xcode/DerivedData -type d -name '*.xcresult' 2>/dev/null | xargs -I{} stat -f '%m {}' {} 2>/dev/null | sort -rn | head -1 | awk '{print \$2}'"
        xcresult_path=$(vm_exec_no_stdin bash -c "${find_cmd}" 2>/dev/null | tr -d '\r' | tail -1)
        if [[ -z "${xcresult_path}" ]]; then
            log "no .xcresult found inside VM to pull"
            return 1
        fi
    fi

    log "pulling xcresult: ${xcresult_path} → ${dest}/"
    if ! vm_exec_no_stdin bash -c "tar -C \"\$(dirname '${xcresult_path}')\" -czf - \"\$(basename '${xcresult_path}')\"" \
        | tar -C "${dest}" -xzf -; then
        log "xcresult tar pipeline failed"
        return 1
    fi

    # Update the "latest" symlink for easy access.
    ln -sfn "${stamp}" "${E2E_RESULTS_DIR}/latest"

    # Cap retention at the most-recent 5.
    # shellcheck disable=SC2012
    ls -1dt "${E2E_RESULTS_DIR}"/*/ 2>/dev/null \
        | grep -v '/latest/' \
        | tail -n +6 \
        | xargs -I{} rm -rf "{}" 2>/dev/null || true

    # Find the .xcresult bundle inside the dest dir.
    local local_xcresult
    # shellcheck disable=SC2012
    local_xcresult=$(ls -1d "${dest}"/*.xcresult 2>/dev/null | head -1)
    if [[ -z "${local_xcresult}" ]]; then
        log "WARN: pulled xcresult missing inside ${dest}/"
        return 0
    fi

    # Extract screenshots, capture VM logs, verify runtime version,
    # print per-test summary table, and (if anything failed) expand
    # the failure details.
    #
    # `_collect_logs` runs `log show` over ssh inside the VM — the
    # slowest post-test step. It only writes its output file; it
    # doesn't read the xcresult, so we can overlap it with the
    # local xcresult work (`_extract_screenshots`, summaries).
    # `_verify_runtime_version` reads the captured log, so wait for
    # the background job before that step. The brace-grouped
    # subshell keeps the trailing `wait` scoped — no orphan PID
    # if the user ^C's mid-run.
    _collect_logs "${dest}" &
    local logs_pid=$!
    _extract_screenshots "${local_xcresult}" "${dest}/screenshots"
    _print_test_summary "${local_xcresult}"
    _print_failure_summary "${local_xcresult}" "${dest}/screenshots"
    wait "${logs_pid}" 2>/dev/null || true
    _verify_runtime_version "${dest}/logs/photox.log"
    log "xcresult ready: ${dest}/"
}

# Grep the captured unified-log for the launch-time identity lines
# emitted by PhotoX (PhotoXApp.init) and PhotoXCardWatcher (main).
# If a line is present and the version mismatches the expected, that
# means a stale process from a previous run was alive — a real
# correctness problem. If a line is absent, that's a warning (the
# process may not have launched, or crashed before logging).
_verify_runtime_version() {
    local log_path=$1
    [[ -f "${log_path}" ]] || return 0

    local expected
    expected=$(expected_git_describe)

    # PhotoX (main app): one line per process launch, emitted from
    # PhotoXApp.init's Logger(subsystem: "dev.frostman.PhotoX",
    # category: "boot"). The os_log printer renders our `=` literal
    # verbatim.
    local app_lines app_versions
    app_lines=$(grep -E 'PhotoX launching: GitDescribe=' "${log_path}" 2>/dev/null || true)
    if [[ -z "${app_lines}" ]]; then
        log "WARN: no \`PhotoX launching\` line in captured logs — running app version unverified"
    else
        app_versions=$(echo "${app_lines}" \
            | grep -oE 'GitDescribe=[^[:space:]]+' \
            | sed 's/^GitDescribe=//' | sort -u)
        if [[ "${app_versions}" != "${expected}" ]]; then
            die runtime-version-mismatch "PhotoX runtime version mismatch: log shows '${app_versions}', expected '${expected}'"
        fi
        log "runtime verified: PhotoX log shows GitDescribe=${expected}"
    fi

    # PhotoXCardWatcher: emits `startup. version=<v> URL scheme=…` at
    # applicationDidFinishLaunching (PhotoXCardWatcher/main.swift).
    # The helper only logs if SMAppService approved + launched it.
    # We don't enforce its presence (LoginItem approval is interactive
    # in macOS Tahoe), but if present, the version MUST match.
    local helper_lines helper_versions
    helper_lines=$(grep -E 'startup\. version=' "${log_path}" 2>/dev/null || true)
    if [[ -n "${helper_lines}" ]]; then
        helper_versions=$(echo "${helper_lines}" \
            | grep -oE 'version=[^[:space:]]+' \
            | sed 's/^version=//' | sort -u)
        if [[ "${helper_versions}" != "${expected}" ]]; then
            die runtime-version-mismatch "PhotoXCardWatcher runtime version mismatch: log shows '${helper_versions}', expected '${expected}'"
        fi
        log "runtime verified: PhotoXCardWatcher log shows version=${expected}"
    fi
}

# Bulk-export every attachment (screenshots, screen recordings,
# synthesized events) from the xcresult bundle. Uses xcresulttool's
# `export attachments` which emits per-attachment files named by
# Apple's internal UUID, plus a manifest.json mapping them back to
# test cases + human-readable names. We post-process the manifest
# to rename files into `${dest_dir}/<test>/<suggested-name>` so the
# layout is browsable without consulting the manifest.
_extract_screenshots() {
    local xcresult=$1 dest_dir=$2
    mkdir -p "${dest_dir}"

    # Stage into a temp scratch dir so the final layout is clean
    # (manifest.json + UUID-named files aren't useful at the top level).
    local stage
    stage=$(mktemp -d -t photox-attach.XXXXXX)
    if ! xcrun xcresulttool export attachments \
            --path "${xcresult}" \
            --output-path "${stage}" >/dev/null 2>&1; then
        rm -rf "${stage}"
        return 0
    fi
    local manifest="${stage}/manifest.json"
    [[ -f "${manifest}" ]] || { rm -rf "${stage}"; return 0; }

    local count=0
    # Iterate per-test, per-attachment via jq.
    while IFS=$'\t' read -r test exported suggested; do
        [[ -z "${test}" ]] && continue
        local test_dir="${dest_dir}/${test//\//_}"
        mkdir -p "${test_dir}"
        # Sanitize the suggested name; preserve extension if present.
        local clean_name="${suggested// /_}"
        clean_name="${clean_name//\//_}"
        local out="${test_dir}/${clean_name}"
        if [[ -f "${stage}/${exported}" ]] \
                && cp "${stage}/${exported}" "${out}" 2>/dev/null; then
            count=$((count + 1))
        fi
    done < <(jq -r '
        .[] | .testIdentifier as $t
        | (.attachments // []) | .[]
        | "\($t)\t\(.exportedFileName)\t\(.suggestedHumanReadableName)"' "${manifest}" 2>/dev/null || true)
    rm -rf "${stage}"
    if (( count > 0 )); then
        log "extracted ${count} attachment(s) → ${dest_dir}/"
    fi
}

# Walk the xcresult's test tree and print a one-line-per-test
# summary table with result + wall-clock + identifier. Always runs
# (success or failure) so the user gets a quick at-a-glance picture
# of what ran and how long it took. The deeper `_print_failure_summary`
# follows with assertion text + screenshot paths for failing rows.
_print_test_summary() {
    local xcresult=$1

    local tests_json
    tests_json=$(xcrun xcresulttool get test-results tests --path "${xcresult}" 2>/dev/null) || return 0
    [[ -z "${tests_json}" ]] && return 0

    # Walk the tree permissively (`..`) so a future xcresult schema
    # change doesn't silently swallow the table. Sort by identifier
    # for stable output.
    local cases
    cases=$(echo "${tests_json}" | jq -r '
        [.. | objects | select(.nodeType? == "Test Case")
         | {
             name: (.nodeIdentifier // .name // "<unnamed>"),
             result: (.result // "Unknown"),
             duration: (.durationInSeconds // 0)
           }]
        | sort_by(.name)
        | .[]
        | "\(.result)\t\(.duration)\t\(.name)"
    ' 2>/dev/null || true)

    [[ -z "${cases}" ]] && return 0

    # awk does the formatting + totals in one pass — keeps the bash
    # side from juggling floats.
    echo
    echo "${cases}" | awk -F'\t' '
        function label(r) {
            if (r == "Passed")  return "PASS"
            if (r == "Failed" || r == "Errored") return "FAIL"
            if (r == "Skipped") return "SKIP"
            return r
        }
        {
            total++
            if ($1 == "Passed")                       passed++
            else if ($1 == "Failed" || $1 == "Errored") failed++
            else if ($1 == "Skipped")                 skipped++
            else                                      other++
            total_dur += $2
            rows[NR] = sprintf("%-4s  %6.2fs  %s", label($1), $2, $3)
        }
        END {
            unit = (total == 1 ? "test" : "tests")
            printf "Test results: %d passed, %d failed, %d skipped — %.2fs total (%d %s)\n\n",
                   passed+0, failed+0, skipped+0, total_dur+0, total+0, unit
            for (i = 1; i <= NR; i++) print rows[i]
        }'
    echo
}

# Parse failing tests + assertion text and print a compact summary.
_print_failure_summary() {
    local xcresult=$1 screenshots_dir=$2

    local tests_json
    if ! tests_json=$(xcrun xcresulttool get test-results tests \
            --path "${xcresult}" 2>/dev/null); then
        return 0
    fi

    local failures
    failures=$(echo "${tests_json}" | jq -r '
        [.testNodes[]?.children[]?.children[]?.children[]?
         | select(.nodeType == "Test Case" and (.result == "Failed" or .result == "Errored"))
         | {name: .name,
            messages: [.children[]? | select(.nodeType == "Failure Message") | .name]}]
        | length' 2>/dev/null || echo 0)

    if [[ "${failures}" == "0" || -z "${failures}" ]]; then
        return 0
    fi

    echo
    echo "FAILURES (${failures}):"
    echo "${tests_json}" | jq -r --arg shots "${screenshots_dir}" '
        [.testNodes[]?.children[]?.children[]?.children[]?
         | select(.nodeType == "Test Case" and (.result == "Failed" or .result == "Errored"))]
        | .[] |
        "  • \(.name)\n" +
        ([.children[]? | select(.nodeType == "Failure Message") | "      " + .name] | join("\n")) +
        "\n      screenshots: \($shots)/\(.name | gsub("/"; "_"))/"' 2>/dev/null || true
}

# Write a tiny JSON file the vm-status recipe reads.
_write_last_run() {
    local outcome=$1 exit_code=$2
    cat > "${LAST_RUN_FILE}" <<EOF
{
  "outcome": "${outcome}",
  "exit_code": ${exit_code},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host_dd": "${HOST_DD}",
  "last_xcresult": "${E2E_RESULTS_DIR}/latest"
}
EOF
}

# Read the failing test identifiers (`Class/test_method()`) out of
# an xcresult bundle. Returns one identifier per line on stdout;
# empty when nothing failed (or the bundle is missing).
_collect_failing_test_ids() {
    local xcresult=$1
    [[ -d "${xcresult}" ]] || return 0
    local tests_json
    tests_json=$(xcrun xcresulttool get test-results tests \
        --path "${xcresult}" 2>/dev/null) || return 0
    [[ -z "${tests_json}" ]] && return 0
    # Same permissive walk shape as `_print_test_summary` so a
    # future xcresult schema tweak doesn't silently break this.
    echo "${tests_json}" | jq -r '
        [.. | objects | select(.nodeType? == "Test Case"
            and (.result == "Failed" or .result == "Errored"))
         | (.nodeIdentifier // .name // "")]
        | map(select(length > 0)) | .[]
    ' 2>/dev/null || true
}

# Wrapper around cmd_suspend that honors --keep-on-fail and the
# pre-existing PHOTOX_E2E_NO_SUSPEND escape hatch. $1 is the rc the
# tests exited with (0 = pass, non-0 = fail).
_maybe_suspend() {
    local rc=$1
    if [[ "${PHOTOX_E2E_NO_SUSPEND:-0}" == "1" ]]; then
        log "PHOTOX_E2E_NO_SUSPEND=1 — leaving VM running"
        return 0
    fi
    if (( keep_on_fail )) && (( rc != 0 )); then
        log "--keep-on-fail and tests failed — leaving VM running for vm-shell / vm-screen"
        return 0
    fi
    cmd_suspend
}

cmd_suspend() {
    if [[ "${PHOTOX_E2E_NO_SUSPEND:-0}" == "1" ]]; then
        log "PHOTOX_E2E_NO_SUSPEND=1 — leaving VM running"
        return 0
    fi
    if [[ "$(vm_state)" != "running" ]]; then
        return 0
    fi
    log "suspending VM ${VM_NAME} (resumes in ~7 s next run)…"
    tart suspend "${VM_NAME}" 2>&1 | tee -a "${VM_RUN_LOG}" || true
    # `tart suspend` returns once the snapshot is durable, but the
    # tart-run process's flock on the VM's auxiliary-storage backing
    # file lags the suspend RPC by a beat. Without this settle, the
    # next `tart run` (the resume in the following invocation) races
    # the lock release and fails with VZErrorDomain Code=2 /
    # NSPOSIXErrorDomain Code=35 (EAGAIN, "Resource temporarily
    # unavailable"). Observed in 49 lines of run.log across a 20-run
    # stability session — i.e. nearly every back-to-back resume.
    # Wait for tart to report the VM out of the running state (the
    # tart-run process has exited), then sleep a beat for the kernel
    # to flush the lock release. The 1 s baseline is empirical:
    # shorter values still raced; 1 s eliminated the EAGAIN entirely
    # in follow-up testing.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ "$(vm_state)" != "running" ]] && break
        sleep 0.5
    done
    sleep 1
    # Tart's `run` process exits when suspend completes. Clear stale
    # PID so the next ensure-running starts fresh.
    rm -f "${VM_PID_FILE}"
}

cmd_down() {
    if [[ -f "${VM_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${VM_PID_FILE}")
        kill "${pid}" 2>/dev/null || true
    fi
    tart stop "${VM_NAME}" 2>/dev/null || true
    rm -f "${VM_PID_FILE}"
    log "VM ${VM_NAME} stopped"
}

cmd_shell() {
    cmd_ensure_running
    local ip
    ip=$(vm_ip)
    log "ssh ${VM_USER}@${ip} (key auth via ${SSH_KEY}, password fallback: ${VM_PASS})"
    exec ssh "${SSH_OPTS[@]}" "${VM_USER}@${ip}"
}

# Stop the headless VM and re-launch it with VZ's VNC server
# exposed, then `open` the VNC URL Tart prints to stdout to launch
# macOS Screen Sharing. The default boot uses `--no-graphics` to
# stay invisible; `--vnc-experimental` pops a Screen Sharing window
# automatically, which is what the user actually wants here — but
# only on demand. The VM stays in VNC mode until the next
# `just vm-down`; subsequent `just vm-e2e` cold-boots back to
# `--no-graphics`.
cmd_screen() {
    log "switching VM ${VM_NAME} to VNC mode (one-time restart, ~10 s)…"
    cmd_down >/dev/null 2>&1 || true
    rm -f "${VM_PID_FILE}"
    wc -l < "${VM_RUN_LOG}" 2>/dev/null | tr -d ' ' \
        > "${VM_RUN_LOG}.cursor" \
        || echo 0 > "${VM_RUN_LOG}.cursor"
    nohup tart run --vnc-experimental --no-audio --no-clipboard --suspendable \
        "${VM_NAME}" >> "${VM_RUN_LOG}" 2>&1 &
    echo $! > "${VM_PID_FILE}"

    # Poll for the VNC URL Tart prints on startup. 30 s ceiling.
    local url=""
    local deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        url=$(grep -oE 'vnc://[^[:space:]]+' "${VM_RUN_LOG}" 2>/dev/null | tail -1)
        [[ -n "${url}" ]] && break
        sleep 1
    done
    if [[ -z "${url}" ]]; then
        die screen-no-url "no vnc:// URL appeared in ${VM_RUN_LOG} within 30 s"
    fi
    log "VNC: ${url}"
    open "${url}"
    log "(VM stays in VNC mode until \`just vm-down\`; \`just vm-e2e\` cold-boots back to no-graphics)"
}

cmd_clean() {
    cmd_ensure_running
    log "wiping ~admin/test-artifacts + DerivedData inside VM (preserves sample/)"
    vm_ssh "rm -rf '${VM_ARTIFACTS}' '${VM_HOME}/Library/Developer/Xcode/DerivedData'/PhotoX-*"
    log "clean complete — next vm-e2e will re-ship and re-build"
}

cmd_pull() {
    log "force-pull ${IMAGE} and recreate VM (~80 GB delete + re-occupy, ~30 s re-provision)…"
    rm -f "${IMAGE_STATE_FILE}" "${VM_IMAGE_STATE_FILE}"
    cmd_down >/dev/null 2>&1 || true
    if vm_exists; then
        tart delete "${VM_NAME}" || die vm-recreate-failed "tart delete failed"
    fi
    cmd_ensure_image
    cmd_ensure_vm
    cmd_ensure_running
    cmd_ensure_provisioned
    log "VM ${VM_NAME} freshly minted from ${IMAGE}"
}

cmd_status() {
    local state
    state=$(vm_state 2>/dev/null || echo "unknown")
    echo "VM:    ${VM_NAME}"
    echo "State: ${state}"

    # Disk usage of the VM's tart directory (includes suspend snapshot).
    local tart_dir="${HOME}/.tart/vms/${VM_NAME}"
    if [[ -d "${tart_dir}" ]]; then
        local sz
        sz=$(du -sh "${tart_dir}" 2>/dev/null | awk '{print $1}')
        echo "Disk:  ${sz}"
    fi

    if [[ -f "${LAST_RUN_FILE}" ]]; then
        echo "Last run:"
        jq -r '"  outcome: \(.outcome)\n  exit:    \(.exit_code)\n  when:    \(.timestamp)\n  result:  \(.last_xcresult)"' \
            "${LAST_RUN_FILE}" 2>/dev/null || cat "${LAST_RUN_FILE}"
    else
        echo "Last run: (no record yet)"
    fi
}

# ── Dispatch ────────────────────────────────────────────────────────────────

case "${1:-}" in
    ensure-image)       shift; cmd_ensure_image "$@" ;;
    ensure-vm)          shift; cmd_ensure_vm "$@" ;;
    ensure-running)     shift; cmd_ensure_running "$@" ;;
    ensure-provisioned) shift; cmd_ensure_provisioned "$@" ;;
    host-build)         shift; cmd_host_build "$@" ;;
    ship)               shift; cmd_ship "$@" ;;
    run)                shift; cmd_run "$@" ;;
    pull-xcresult)      shift; cmd_pull_xcresult "$@" ;;
    suspend)            shift; cmd_suspend "$@" ;;
    down)               shift; cmd_down "$@" ;;
    shell)              shift; cmd_shell "$@" ;;
    screen)             shift; cmd_screen "$@" ;;
    clean)              shift; cmd_clean "$@" ;;
    pull)               shift; cmd_pull "$@" ;;
    status)             shift; cmd_status "$@" ;;
    up)
        cmd_ensure_image
        cmd_ensure_vm
        cmd_ensure_running
        cmd_ensure_provisioned
        log "VM ready — \`just vm-e2e\` will ship artifacts and run"
        ;;
    "")
        die usage "no subcommand given (try one of: up, run, ship, down, shell, screen, clean, pull, status)"
        ;;
    *)
        die usage "unknown subcommand: $1"
        ;;
esac
