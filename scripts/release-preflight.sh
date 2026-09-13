#!/bin/bash
# Release preflight — verify CI passed on the exact commit being published.
#
# Usage:
#   ./scripts/release-preflight.sh <sha> [repo]
#   ./scripts/release-preflight.sh --dry-run <sha> [repo]
#
# Checks:
#   - a trusted main CI run on <sha> must have succeeded   → hard gate
#   - scheduled debug perf-validation is advisory          → warning only
#   - packaged-app perf signoff runs later in release.yml  → hard gate
#
# This mirrors `release-candidate.py::check_ci`, which is the gate that
# actually guards signing credentials: a run of the `ci.yml` workflow, on
# branch main, from a `push` or `workflow_dispatch` event in this repository,
# completed with conclusion success, whose head_sha is <sha> exactly. A
# preflight that answered a laxer question than the gate it previews is worse
# than no preflight — it reports "passed" for a release the gate then refuses.
#
# Two things this deliberately does not accept:
#
#   - `build-and-test-fallback` (the "CI Fallback" workflow). It is not a
#     second opinion on the same build. It omits the release-shaped steps that
#     exist because v0.24.0 burned four environment assumptions: the
#     `build-release.sh --no-sign` bundling path, the unsigned-bundle
#     structure check, the perf-gate runnability probe, the release-harness
#     absence check, the subprocess-timeout tripwire and the isolated render
#     suite. It also provisions differently — no pinned mise, no locked Zig,
#     no uv, shallow checkout. Its `workflow_run` runs execute on the default
#     branch, so GitHub attaches their check-runs to main's head rather than
#     to the commit CI ran on: a `build-and-test-fallback` entry on a SHA is
#     usually not a statement about that SHA at all.
#
#   - "this commit changed no build inputs, so an older green build still
#     describes it." The reasoning is sound but the premise went unverified,
#     and CI on main cancels in-progress runs per ref, so an ancestor whose
#     build was cancelled is an ordinary occurrence rather than a rare one.
#     Build inputs since the last green ancestor are reported below as
#     context for the operator; they do not decide the exit code.
#
# Exit codes:
#   0  all required checks passed
#   1  a required check failed or was not found
#   2  invalid arguments or environment configuration

set -euo pipefail

REQUIRED_CI_WORKFLOW="ci.yml"
REQUIRED_CI_JOB="build-and-test"
ADVISORY_PERF_CHECKS=("perf-validation" "capture")

# ci.yml's push path filter, mirrored. Kept honest by the parity test in
# scripts/tests/test_release_preflight.py. `*` inside a [[ == ]] pattern spans
# `/`, so "Sources/*" covers the whole subtree the way "Sources/**" does in the
# workflow. Used for operator context only — never to waive the gate.
CI_RELEVANT_PATH_PATTERNS=(
    "Sources/*"
    "Tests/*"
    "XcodeCloudHarness/*"
    "WorkSpacesCloudCI.xcodeproj/*"
    "ci_scripts/*"
    ".github/workflows/ci.yml"
    ".github/workflows/ci-fallback.yml"
    ".github/workflows/release.yml"
    ".swift-format"
    ".mise.toml"
    "mise.lock"
    "Package.swift"
    "Package.resolved"
    "WorkspaceManager.entitlements"
    "scripts/build-ghosttykit.sh"
    "scripts/build-release.sh"
    "scripts/check-perf-benchmarks.py"
    "scripts/check-release-harness-absence.sh"
    "scripts/check-subprocess-timeouts.py"
    "scripts/generate-sparkle-appcast.sh"
    "scripts/install-local.sh"
    "scripts/lib/release-signing.sh"
    "scripts/notarize.sh"
    "scripts/prepare-prerelease.sh"
    "scripts/prepare-release.sh"
    "scripts/release-preflight.sh"
    "scripts/release-candidate.py"
    "scripts/release-environments.py"
    "scripts/release.py"
    "scripts/verify-release-candidate.sh"
    "scripts/release-version.sh"
    "scripts/setup-release-secrets.sh"
    "scripts/verify-app-keychain-signing.sh"
    "scripts/verify-ghostty-pin.sh"
    "scripts/verify-installed-perf.sh"
    "scripts/verify-p12.sh"
    "scripts/verify-release-bundle.sh"
)

DRY_RUN=false
SHA=""
REPO="${GITHUB_REPOSITORY:-fairchild/workspaces}"
POLL_SECONDS="${RELEASE_PREFLIGHT_POLL_SECONDS:-15}"
TIMEOUT_SECONDS="${RELEASE_PREFLIGHT_TIMEOUT_SECONDS:-900}"
ANCESTOR_SCAN_RUNS="${RELEASE_PREFLIGHT_ANCESTOR_SCAN_RUNS:-30}"
LISTED_BUILD_INPUTS=10
CI_RESULT="not_found"
CI_ELAPSED=0

usage() {
    cat <<'USAGE'
Usage: ./scripts/release-preflight.sh [--dry-run] <sha> [repo]

Verify release-blocking checks for the exact commit being published.
USAGE
}

parse_args() {
    if [[ "${1:-}" == "--dry-run" ]]; then
        DRY_RUN=true
        shift
    fi

    if [[ $# -lt 1 || $# -gt 2 ]]; then
        usage >&2
        exit 2
    fi

    SHA="$1"
    REPO="${2:-$REPO}"
}

validate_config() {
    if ! [[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] || (( POLL_SECONDS < 1 )); then
        echo "RELEASE_PREFLIGHT_POLL_SECONDS must be a positive integer" >&2
        exit 2
    fi
    if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
        echo "RELEASE_PREFLIGHT_TIMEOUT_SECONDS must be a non-negative integer" >&2
        exit 2
    fi
    if ! [[ "$ANCESTOR_SCAN_RUNS" =~ ^[0-9]+$ ]] || (( ANCESTOR_SCAN_RUNS < 1 )); then
        echo "RELEASE_PREFLIGHT_ANCESTOR_SCAN_RUNS must be a positive integer" >&2
        exit 2
    fi
}

print_header() {
    echo "=== Release Preflight ==="
    echo "SHA:  $SHA"
    echo "Repo: $REPO"
    echo ""
}

is_ci_relevant_path() {
    local path="$1"
    local pattern

    for pattern in "${CI_RELEVANT_PATH_PATTERNS[@]}"; do
        # shellcheck disable=SC2053  # pattern is a glob on purpose
        if [[ "$path" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Return the state of the newest trusted CI run for this exact SHA.
#
# Trusted means what release-candidate.py means by it: the ci.yml workflow, on
# main, raised by a push or an explicit workflow_dispatch, in this repository.
# A rerun gets a new run id on the same head_sha, so the highest id wins the
# same way the release gate picks its run.
#
# - terminal conclusions such as success, failure, cancelled
# - queued or in_progress while GitHub Actions is still running
# - not_found when no trusted CI run exists for the commit
latest_ci_run_state() {
    local runs
    local run_id status conclusion
    local newest_id=-1
    local state="not_found"

    if ! runs=$(gh api \
        "repos/$REPO/actions/workflows/$REQUIRED_CI_WORKFLOW/runs?head_sha=$SHA&branch=main&per_page=100" \
        --jq ".workflow_runs[]
              | select((.event == \"push\" or .event == \"workflow_dispatch\")
                       and .head_repository.full_name == \"$REPO\")
              | [.id, .status, (.conclusion // \"__no_conclusion__\")]
              | @tsv" \
        2>/dev/null); then
        echo "not_found"
        return
    fi

    while IFS=$'\t' read -r run_id status conclusion; do
        [[ -n "${run_id:-}" ]] || continue
        (( run_id > newest_id )) || continue

        newest_id="$run_id"
        if [[ "$status" == "completed" ]]; then
            if [[ "$conclusion" == "__no_conclusion__" ]]; then
                state="completed"
            else
                state="$conclusion"
            fi
        else
            state="${status:-not_found}"
        fi
    done <<<"$runs"

    echo "$state"
}

# Return the latest check-run state for this SHA. Advisory checks only: they
# are check-run names rather than workflows, and busy release commits spill
# past the first API page, so collect every page and take the newest match.
check_workflow_state() {
    local workflow_name="$1"
    local check_runs
    local name status conclusion timestamp
    local latest_state="not_found"
    local latest_timestamp="0000-00-00T00:00:00Z"

    if ! check_runs=$(gh api \
        --paginate \
        "repos/$REPO/commits/$SHA/check-runs?per_page=100" \
        --jq '.check_runs[] | [.name, .status, (.conclusion // "__no_conclusion__"), (.started_at // .created_at // "0000-00-00T00:00:00Z")] | @tsv' \
        2>/dev/null); then
        echo "not_found"
        return
    fi

    while IFS=$'\t' read -r name status conclusion timestamp; do
        [[ -n "${name:-}" ]] || continue
        [[ "$name" == "$workflow_name" ]] || continue
        [[ "$timestamp" > "$latest_timestamp" ]] || continue

        latest_timestamp="$timestamp"
        if [[ "$status" == "completed" ]]; then
            if [[ "$conclusion" == "__no_conclusion__" ]]; then
                latest_state="completed"
            else
                latest_state="$conclusion"
            fi
        else
            latest_state="${status:-not_found}"
        fi
    done <<<"$check_runs"

    echo "$latest_state"
}

check_any_workflow() {
    local workflow_name
    local result="not_found"

    for workflow_name in "$@"; do
        result=$(check_workflow_state "$workflow_name")
        if [[ "$result" != "not_found" ]]; then
            echo "$result"
            return
        fi
    done
    echo "not_found"
}

# A commit with no CI run of its own has no build, and waiting cannot conjure
# one: GitHub registers a run within seconds of the event that starts it, so
# absence here means no event ever matched, not that one is pending. Report it
# and let the operator raise the run deliberately.
should_stop_waiting_for_ci() {
    if [[ "$CI_RESULT" == "not_found" ]]; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    if (( CI_ELAPSED >= TIMEOUT_SECONDS )); then
        return 0
    fi
    return 1
}

wait_for_required_ci() {
    CI_RESULT="not_found"
    CI_ELAPSED=0

    echo -n "CI ($REQUIRED_CI_JOB): "
    while true; do
        CI_RESULT=$(latest_ci_run_state)
        case "$CI_RESULT" in
            queued | in_progress | not_found)
                if should_stop_waiting_for_ci; then
                    break
                fi
                echo "${CI_RESULT}; waiting ${POLL_SECONDS}s"
                sleep "$POLL_SECONDS"
                CI_ELAPSED=$((CI_ELAPSED + POLL_SECONDS))
                echo -n "CI ($REQUIRED_CI_JOB): "
                ;;
            *)
                break
                ;;
        esac
    done
}

print_dispatch_remedy() {
    echo "  No trusted main CI run exists for this commit."
    echo "  ci.yml's path filter keeps hosted macOS CI on build inputs, so an"
    echo "  ordinary main commit can carry no build of its own. Raise one for"
    echo "  the exact commit you intend to release, then re-run this preflight:"
    echo "    gh workflow run ci.yml --ref main"
    echo "  release-candidate.py accepts that workflow_dispatch run as trusted."
}

report_required_ci() {
    case "$CI_RESULT" in
        success)
            echo "PASS"
            return 0
            ;;
        queued | in_progress)
            if [[ "$DRY_RUN" == true ]]; then
                echo "${CI_RESULT} (dry-run: continuing)"
                return 0
            fi
            echo "TIMEOUT ($CI_RESULT after ${CI_ELAPSED}s)"
            return 1
            ;;
        not_found)
            if [[ "$DRY_RUN" == true ]]; then
                echo "NOT FOUND (dry-run: continuing)"
                return 0
            fi
            echo "NOT FOUND"
            print_dispatch_remedy
            return 1
            ;;
        *)
            echo "FAIL ($CI_RESULT)"
            return 1
            ;;
    esac
}

# The newest successful trusted CI run whose commit is an ancestor of (or is)
# the release SHA. Compare answers ancestry and range contents in one call:
# "ahead" means the release SHA is ahead of the candidate, "identical" means
# they are the same commit.
nearest_green_ci_ancestor() {
    local candidates candidate status

    if ! candidates=$(gh api \
        "repos/$REPO/actions/workflows/$REQUIRED_CI_WORKFLOW/runs?branch=main&status=success&per_page=$ANCESTOR_SCAN_RUNS" \
        --jq ".workflow_runs[]
              | select((.event == \"push\" or .event == \"workflow_dispatch\")
                       and .head_repository.full_name == \"$REPO\")
              | .head_sha" \
        2>/dev/null); then
        return 1
    fi

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if [[ "$candidate" == "$SHA" ]]; then
            echo "$candidate"
            return 0
        fi
        status=$(gh api "repos/$REPO/compare/$candidate...$SHA" --jq '.status' 2>/dev/null) || continue
        if [[ "$status" == "ahead" || "$status" == "identical" ]]; then
            echo "$candidate"
            return 0
        fi
    done <<<"$candidates"

    return 1
}

# Context, not permission. Tells the operator what a dispatched CI run would
# cover: if nothing since the last green ancestor touched a build input, the
# run should reproduce that green; if something did, it is the first place to
# look when it does not.
report_build_inputs_since_green() {
    local ancestor files file
    local changed=()

    echo -n "Last green CI ancestor: "
    if ! ancestor=$(nearest_green_ci_ancestor); then
        echo "none in the last $ANCESTOR_SCAN_RUNS successful main CI runs"
        return
    fi
    if [[ "$ancestor" == "$SHA" ]]; then
        echo "this commit"
        return
    fi
    echo "${ancestor:0:12}"

    echo -n "Build inputs changed since it: "
    if ! files=$(gh api "repos/$REPO/compare/$ancestor...$SHA" --jq '(.files // [])[].filename' 2>/dev/null); then
        echo "unknown (compare unavailable)"
        return
    fi

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if is_ci_relevant_path "$file"; then
            changed+=("$file")
        fi
    done <<<"$files"

    if (( ${#changed[@]} == 0 )); then
        echo "none"
        return
    fi

    echo "${#changed[@]}"
    for file in "${changed[@]:0:$LISTED_BUILD_INPUTS}"; do
        echo "    $file"
    done
    if (( ${#changed[@]} > LISTED_BUILD_INPUTS )); then
        echo "    … and $(( ${#changed[@]} - LISTED_BUILD_INPUTS )) more"
    fi
}

report_perf_validation() {
    local perf_result

    echo -n "Perf validation: "
    perf_result=$(check_any_workflow "${ADVISORY_PERF_CHECKS[@]}")
    case "$perf_result" in
        success)
            echo "PASS"
            ;;
        not_found)
            echo "NOT FOUND (advisory — perf may not have run on this SHA)"
            ;;
        *)
            echo "WARN ($perf_result) — perf regression detected but not blocking release"
            ;;
    esac
}

finish_preflight() {
    local exit_code="$1"

    echo ""
    if [[ "$exit_code" -eq 0 ]]; then
        echo "Preflight passed."
    else
        echo "Preflight FAILED — required checks did not pass on $SHA."
        echo "Do not publish this release until CI is green on this exact commit."
    fi

    exit "$exit_code"
}

main() {
    local exit_code=0

    parse_args "$@"
    validate_config
    print_header

    # Required gate: a trusted main CI run must have succeeded on this exact
    # commit. There is no path-filter waiver — release-candidate.py grants none
    # either, and a preflight that did would preview a release the gate refuses.
    wait_for_required_ci
    if ! report_required_ci; then
        exit_code=1
    fi

    report_build_inputs_since_green

    # Advisory gate: performance validation is useful release context, but it
    # should not block signing/publishing by itself.
    report_perf_validation

    finish_preflight "$exit_code"
}

main "$@"
