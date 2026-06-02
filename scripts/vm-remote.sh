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
# proxy (size + accessed timestamp shift when Cirrus rebuilds).
image_state() {
    tart list --source oci --format json 2>/dev/null \
        | jq -c --arg img "${IMAGE}" \
            'map(select(.Name == $img)) | .[0] // empty' \
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

# tart exec wrappers. `-i` only when the parent stdin is a pipe;
# `-t` only when stdin is a TTY (so CI / pipe invocations don't
# break). The two variants exist so callers that supply stdin
# (cat | …) don't allocate a redundant pty.
vm_exec() {
    local tty_flag=""
    [[ -t 0 ]] && tty_flag="-t"
    tart exec -i ${tty_flag} "${VM_NAME}" "$@"
}

vm_exec_no_stdin() {
    local tty_flag=""
    [[ -t 0 ]] && tty_flag="-t"
    tart exec ${tty_flag} "${VM_NAME}" "$@"
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

# Git-derived version strings, matching `just dev`'s logic exactly
# so vm-e2e and just dev produce binaries with consistent identity.
git_describe_args() {
    local sha9 dirty=""
    sha9=$(git rev-parse --short=9 HEAD)
    [[ -n "$(git status --porcelain)" ]] && dirty="-dirty"
    printf 'MARKETING_VERSION=0.0.0 CURRENT_PROJECT_VERSION=0 GIT_DESCRIBE=v0.0.0-dev-%s%s' \
        "${sha9}" "${dirty}"
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

    # Poll for Guest Agent readiness. Watch the run log for
    # VZErrorDomain Code=12 (corrupted suspend snapshot) — if seen,
    # kill the tart process and cold-boot. The cursor stored by
    # _tart_run_suspendable bounds the search to THIS spawn's log
    # lines (otherwise we'd match stale errors from prior sessions
    # and loop forever).
    local deadline=$((SECONDS + 90))
    local recovered=0
    while (( SECONDS < deadline )); do
        if tart ip --resolver agent --wait 2 "${VM_NAME}" >/dev/null 2>&1; then
            log "VM ${VM_NAME} is up"
            return 0
        fi
        local cursor
        cursor=$(cat "${VM_RUN_LOG}.cursor" 2>/dev/null || echo 0)
        if tail -n "+$((cursor + 1))" "${VM_RUN_LOG}" 2>/dev/null \
                | grep -q "VZErrorDomain Code=12" && (( recovered == 0 )); then
            recovered=1
            log "suspend snapshot is corrupted — falling back to cold-boot"
            local pid
            pid=$(cat "${VM_PID_FILE}" 2>/dev/null || echo 0)
            kill "${pid}" 2>/dev/null || true
            sleep 1
            tart stop "${VM_NAME}" 2>/dev/null || true
            _tart_run_suspendable
            # Reset the deadline for the cold-boot attempt.
            deadline=$((SECONDS + 90))
        fi
        sleep 2
    done
    die vm-unreachable "VM started but tart-guest-agent never responded (90 s) — check ${VM_RUN_LOG}"
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

# Run xcodebuild build-for-testing on the host with an isolated
# DerivedData. Mirrors the version overrides used by `just dev` so
# the binary's About panel still reads like a real dev build.
cmd_host_build() {
    cmd_ensure_provisioned
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
    log "host build complete"
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
# #file walk. Uses plutil to mutate the plist in place. Returns the
# (possibly-rewritten) path to use for shipping.
_patch_xctestrun_env() {
    local src=$1
    local patched
    patched="$(dirname "${src}")/.patched-$(basename "${src}")"
    cp "${src}" "${patched}"

    # The xctestrun's top-level keys are the BlueprintNames of the
    # test targets. We only need PhotoXUITests to see the env var
    # (PhotoXTests is a unit-test target that doesn't touch sample/).
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

# Headline ship: build on host, ship artifacts, ship fixtures.
cmd_ship() {
    cmd_host_build
    _ship_artifacts
    _ship_fixtures
}

# Read the env var override for the test runner so PhotoXUITestCase's
# repoSampleURL resolves to the VM's fixture path instead of the
# host's compile-time #file walk-up.
_test_env_args() {
    printf 'PHOTOX_FIXTURE_SOURCE_DIR=%s/sample' "${VM_FIXTURES}"
}

# Two-stage test runner: optional smoke gate, then the caller's
# filter (or full suite if no filter). Both stages share the same
# xctestrun and DerivedData inside the VM.
cmd_run() {
    cmd_ship

    local skip_smoke=0
    if [[ "${PHOTOX_E2E_SKIP_SMOKE:-0}" == "1" ]]; then
        skip_smoke=1
    fi
    # Allow the caller to pass --skip-smoke as the first arg.
    if [[ "${1:-}" == "--skip-smoke" ]]; then
        skip_smoke=1
        shift
    fi

    local filters=("$@")

    # Auto-skip the dedicated smoke gate when the caller's filter
    # already includes SmokeTests (full suite, or an explicit
    # PhotoXUITests/SmokeTests... filter). Avoids running the same
    # test twice on the hot iteration path.
    if (( skip_smoke == 0 )); then
        if [[ ${#filters[@]} -eq 0 ]]; then
            skip_smoke=1
        else
            for f in "${filters[@]}"; do
                if [[ "${f}" == *SmokeTests* ]]; then
                    skip_smoke=1
                    break
                fi
            done
        fi
    fi
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
        vm_exec_no_stdin bash -c "${cmd}"
    }

    # Smoke gate first (fast-fail if launch is broken).
    if (( skip_smoke == 0 )); then
        local smoke_rc=0
        _run_stage "PhotoXUITests/SmokeTests" "smoke gate (PhotoXUITests/SmokeTests)" || smoke_rc=$?
        if (( smoke_rc != 0 )); then
            cmd_pull_xcresult "${xcresult_remote}" || true
            _write_last_run "smoke-failed" "${smoke_rc}"
            cmd_suspend
            die xcodebuild-failed "smoke gate failed (exit ${smoke_rc}) — caller's tests not run"
        fi
    fi

    # Caller's filter (or full suite).
    local rc=0
    if [[ ${#filters[@]} -eq 0 ]]; then
        _run_stage "" "full suite" || rc=$?
    else
        _run_stage "${filters[*]}" "${filters[*]}" || rc=$?
    fi

    cmd_pull_xcresult "${xcresult_remote}" || true
    if (( rc != 0 )); then
        _write_last_run "failed" "${rc}"
        cmd_suspend
        die xcodebuild-failed "test run failed (exit ${rc}) — see ${E2E_RESULTS_DIR}/latest/"
    fi
    _write_last_run "passed" 0
    cmd_suspend
    log "run completed cleanly"
}

# Pull the .xcresult bundle out of the VM and into the host's
# build/e2e-results/<ts>/ tree. Extracts screenshots and prints a
# failure summary if any tests failed. $1 is the in-VM path to the
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

    # Extract screenshots + print failure summary.
    _extract_screenshots "${local_xcresult}" "${dest}/screenshots"
    _print_failure_summary "${local_xcresult}" "${dest}/screenshots"
    log "xcresult ready: ${dest}/"
}

# Walk the xcresult bundle and copy every image attachment into
# ${dest_dir}/<test-name>/<n>.<ext>. Uses xcresulttool's modern
# (Xcode 16+) test-results subcommands.
_extract_screenshots() {
    local xcresult=$1 dest_dir=$2
    mkdir -p "${dest_dir}"

    # The modern subcommand prints a "tests" tree with attachment
    # references. Use --legacy if the new format isn't available.
    local tests_json
    if ! tests_json=$(xcrun xcresulttool get test-results tests \
            --path "${xcresult}" 2>/dev/null); then
        # Fallback to legacy `get` (older Xcode).
        tests_json=$(xcrun xcresulttool get --path "${xcresult}" --format json 2>/dev/null || true)
    fi

    if [[ -z "${tests_json}" ]]; then
        log "WARN: xcresulttool produced no JSON; skipping screenshot extraction"
        return 0
    fi

    # Extract all attachments using xcresulttool's export command.
    # The path layout is intentionally flat per-test for easy `open`.
    local manifest
    manifest=$(echo "${tests_json}" | jq -r '
        [.testNodes[]?.children[]?.children[]?.children[]?
         | select(.nodeType == "Test Case")
         | {test: .name, attachments: [.. | objects | select(.payloadId?) | {id: .payloadId, name: (.name // "attachment")}]}
        ] | .[] | select(.attachments | length > 0)
        | "\(.test)\t\(.attachments | map(.id + "|" + .name) | join(";"))"' 2>/dev/null || true)

    if [[ -z "${manifest}" ]]; then
        return 0
    fi

    local count=0
    while IFS=$'\t' read -r test attachments; do
        [[ -z "${test}" ]] && continue
        local test_dir="${dest_dir}/${test//\//_}"
        mkdir -p "${test_dir}"
        local idx=0
        IFS=';' read -ra entries <<< "${attachments}"
        for entry in "${entries[@]}"; do
            local payload_id="${entry%%|*}"
            local name="${entry#*|}"
            local ext="${name##*.}"
            [[ "${ext}" == "${name}" ]] && ext="png"
            local out="${test_dir}/${idx}-${name// /_}"
            if xcrun xcresulttool export object \
                    --path "${xcresult}" \
                    --id "${payload_id}" \
                    --output-path "${out}" \
                    --type file 2>/dev/null; then
                count=$((count + 1))
            fi
            idx=$((idx + 1))
        done
    done <<< "${manifest}"
    if (( count > 0 )); then
        log "extracted ${count} screenshot(s) → ${dest_dir}/"
    fi
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
        die usage "no subcommand given (try one of: up, run, ship, down, shell, clean, pull, status)"
        ;;
    *)
        die usage "unknown subcommand: $1"
        ;;
esac
