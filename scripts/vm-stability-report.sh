#!/usr/bin/env bash
# Build a flake matrix from a stability run.
#
# Walks build/e2e-results/<ts>/last.xcresult bundles whose timestamp
# is ≥ the argument, aggregates per-test results across them, and
# emits a markdown table on stdout. Designed for `just vm-e2e-stability`
# to consume (it tees this into build/vm/stability/report.md).
#
# Arg: minimum xcresult timestamp in the same compact form xcresult
# dirs use (YYYYMMDDTHHMMSS). Empty / missing arg means "all".
#
# Output columns: test | runs | pass | fail | p50 | p95 | sample failure
#
# Highlights rows where every failure has duration 0.0 (the synthetic
# `PhotoX (NNN) encountered an error` runner-attach signature) so
# they're easy to spot. Reuses the same `xcrun xcresulttool get
# test-results tests` JSON shape that vm-remote.sh:_print_test_summary
# (line 1028) and :_collect_failing_test_ids (1120) already trust.
set -euo pipefail

cd "$(dirname "$0")/.."
RESULTS_ROOT="build/e2e-results"
MIN_TS="${1:-}"

# Collect candidate xcresult bundles.
declare -a XCRESULTS=()
for dir in "${RESULTS_ROOT}"/*/; do
    base=$(basename "${dir%/}")
    # Skip the symlink and anything older than MIN_TS.
    [[ "${base}" == "latest" ]] && continue
    [[ -n "${MIN_TS}" && "${base}" < "${MIN_TS}" ]] && continue
    [[ -d "${dir}last.xcresult" ]] || continue
    XCRESULTS+=("${dir}last.xcresult")
done

if [[ ${#XCRESULTS[@]} -eq 0 ]]; then
    echo "# vm-e2e stability report"
    echo
    echo "_no xcresult bundles found at or after \`${MIN_TS:-(any)}\`_"
    exit 0
fi

# Build a single TSV stream: result\tduration\ttest_id\tfailure_msg
# from every xcresult. `nodeIdentifier` falls back to `name` to keep
# the synthetic `PhotoX (NNN) encountered an error` row identified,
# which is what we want to track. Strip embedded tabs/newlines from
# failure messages so awk's per-line aggregation stays clean.
TSV=$(mktemp -t vm-stability-report.XXXXXX)
trap 'rm -f "${TSV}"' EXIT

for xc in "${XCRESULTS[@]}"; do
    xcrun xcresulttool get test-results tests --path "${xc}" 2>/dev/null \
        | jq -r '
            [.. | objects | select(.nodeType? == "Test Case")
             | {
                 name: (.nodeIdentifier // .name // "<unnamed>"),
                 result: (.result // "Unknown"),
                 duration: (.durationInSeconds // 0),
                 msg: ([.children[]? | select(.nodeType == "Failure Message") | .name] | join(" / "))
               }]
            | .[]
            | "\(.result)\t\(.duration)\t\(.name)\t\(.msg)"
        ' 2>/dev/null \
        | tr -d '\r' \
        | awk -F'\t' 'BEGIN{OFS="\t"} { gsub(/[\t]/, " ", $4); print }' \
        >> "${TSV}" || true
done

RUNS=${#XCRESULTS[@]}

echo "# vm-e2e stability report"
echo
echo "Session start cutoff: \`${MIN_TS:-(any)}\` · runs walked: **${RUNS}**"
echo
echo "| test | runs | pass | fail | p50 | p95 | first failure |"
echo "|---|---:|---:|---:|---:|---:|---|"

# awk does the per-test aggregation in a single pass. Durations are
# sorted per test at the end to compute p50/p95 (only over passing
# durations; failures with duration 0 would skew the picture).
awk -F'\t' '
function pct(arr, n, p,    i) {
    if (n == 0) return 0
    # Sort the slice in place via insertion.
    for (i = 2; i <= n; i++) {
        v = arr[i]; j = i - 1
        while (j >= 1 && arr[j] > v) { arr[j+1] = arr[j]; j-- }
        arr[j+1] = v
    }
    i = int((p/100.0) * (n - 1)) + 1
    if (i < 1) i = 1
    if (i > n) i = n
    return arr[i]
}
{
    name = $3
    if (!(name in seen)) {
        order[++norder] = name
        seen[name] = 1
    }
    runs[name]++
    if ($1 == "Passed") {
        pass[name]++
        # Per-test pass duration list for p50/p95.
        dur_n[name]++
        dur[name, dur_n[name]] = $2 + 0
    } else if ($1 == "Failed" || $1 == "Errored") {
        fail[name]++
        if (msg[name] == "") msg[name] = $4
        if ($2 + 0 == 0) zero_dur_fail[name]++
    } else if ($1 == "Skipped") {
        skip[name]++
    }
}
END {
    # Print rows sorted by name for stable diff against prior reports.
    n = norder
    for (i = 1; i <= n; i++) names[i] = order[i]
    for (i = 2; i <= n; i++) {
        v = names[i]; j = i - 1
        while (j >= 1 && names[j] > v) { names[j+1] = names[j]; j-- }
        names[j+1] = v
    }
    for (i = 1; i <= n; i++) {
        nm = names[i]
        nrun = runs[nm] + 0
        np   = pass[nm] + 0
        nf   = fail[nm] + 0
        # Hung-runner marker: every failure had duration 0.
        marker = ""
        if (nf > 0 && zero_dur_fail[nm] == nf) marker = " ⚠ runner-hang"
        # p50/p95 over passing durations only.
        dn = dur_n[nm] + 0
        if (dn > 0) {
            delete tmp
            for (k = 1; k <= dn; k++) tmp[k] = dur[nm, k]
            p50 = pct(tmp, dn, 50)
            p95 = pct(tmp, dn, 95)
            p50s = sprintf("%.2fs", p50)
            p95s = sprintf("%.2fs", p95)
        } else {
            p50s = "—"
            p95s = "—"
        }
        # Compact failure message — first 80 chars, newlines stripped.
        sample = msg[nm]
        gsub(/\|/, "\\|", sample)
        if (length(sample) > 80) sample = substr(sample, 1, 80) "…"
        if (sample == "") sample = "—"
        printf "| `%s`%s | %d | %d | %d | %s | %s | %s |\n",
            nm, marker, nrun, np, nf, p50s, p95s, sample
    }
}' "${TSV}"
