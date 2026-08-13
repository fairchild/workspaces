#!/bin/bash
# Release preflight — verify CI checks passed on the release SHA before
# signing and publishing proceeds.
#
# Usage:
#   ./scripts/release-preflight.sh <sha> [repo]
#   ./scripts/release-preflight.sh --dry-run <sha> [repo]
#
# Checks:
#   - build-and-test (CI) must have passed on <sha>       → hard gate
#   - scheduled debug perf-validation is advisory          → warning only
#   - packaged-app perf signoff runs later in release.yml  → hard gate
#
# Exit codes:
#   0  all required checks passed
#   1  a required check failed or was not found
#   2  invalid arguments or environment configuration

set -euo pipefail

REQUIRED_CI_CHECK="build-and-test"
ADVISORY_PERF_CHECKS=("perf-validation" "capture")

DRY_RUN=false
SHA=""
REPO="${GITHUB_REPOSITORY:-fairchild/workspaces}"
POLL_SECONDS="${RELEASE_PREFLIGHT_POLL_SECONDS:-15}"
TIMEOUT_SECONDS="${RELEASE_PREFLIGHT_TIMEOUT_SECONDS:-900}"
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
}

print_header() {
    echo "=== Release Preflight ==="
    echo "SHA:  $SHA"
    echo "Repo: $REPO"
    echo ""
}

# Return the latest check-run state for this release SHA.
#
# GitHub can attach many check-runs to busy release commits, so collect every
# paginated page and choose the newest matching check by timestamp.
#
# - terminal conclusions such as success, failure, cancelled
# - queued or in_progress while GitHub Actions is still running
# - not_found when no matching check run exists on the commit
check_workflow_state() {
    local workflow_name="$1"
    local check_runs
    local name
    local status
    local conclusion
    local timestamp
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

is_ci_relevant_path() {
    local path="$1"

    case "$path" in
        Sources/* | Tests/*)
            return 0
            ;;
        .github/workflows/ci.yml | \
            .github/workflows/ci-fallback.yml | \
            .github/workflows/release.yml | \
            .swift-format | \
            Package.swift | \
            Package.resolved | \
            WorkspaceManager.entitlements | \
            scripts/build-ghosttykit.sh | \
            scripts/build-release.sh | \
            scripts/check-perf-benchmarks.py | \
            scripts/check-release-harness-absence.sh | \
            scripts/check-subprocess-timeouts.py | \
            scripts/generate-sparkle-appcast.sh | \
            scripts/install-local.sh | \
            scripts/notarize.sh | \
            scripts/prepare-prerelease.sh | \
            scripts/prepare-release.sh | \
            scripts/release-preflight.sh | \
            scripts/release-version.sh | \
            scripts/setup-release-secrets.sh | \
            scripts/verify-app-keychain-signing.sh | \
            scripts/verify-installed-perf.sh | \
            scripts/verify-p12.sh | \
            scripts/verify-release-bundle.sh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

source_change_count() {
    local changed_files
    local changed_file
    local count=0

    if ! changed_files=$(gh api \
        "repos/$REPO/commits/$SHA" \
        --jq '.files[].filename' \
        2>/dev/null); then
        echo "unknown"
        return
    fi

    while IFS= read -r changed_file; do
        [[ -n "$changed_file" ]] || continue
        if is_ci_relevant_path "$changed_file"; then
            count=$((count + 1))
        fi
    done <<<"$changed_files"

    echo "$count"
}

should_stop_waiting_for_ci() {
    local source_changes="$1"

    if [[ "$source_changes" == "0" && "$CI_RESULT" == "not_found" ]]; then
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
    local source_changes="$1"

    CI_RESULT="not_found"
    CI_ELAPSED=0

    echo -n "CI ($REQUIRED_CI_CHECK): "
    while true; do
        CI_RESULT=$(check_workflow_state "$REQUIRED_CI_CHECK")
        case "$CI_RESULT" in
            queued | in_progress | not_found)
                if should_stop_waiting_for_ci "$source_changes"; then
                    break
                fi
                echo "${CI_RESULT}; waiting ${POLL_SECONDS}s"
                sleep "$POLL_SECONDS"
                CI_ELAPSED=$((CI_ELAPSED + POLL_SECONDS))
                echo -n "CI ($REQUIRED_CI_CHECK): "
                ;;
            *)
                break
                ;;
        esac
    done
}

report_required_ci() {
    local source_changes="$1"

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
            # Release commits typically only touch CHANGELOG.md and do not
            # trigger CI. For source-affecting commits, absence of CI remains a
            # hard release blocker.
            if [[ "$source_changes" == "0" ]]; then
                echo "SKIPPED (no source changes in commit)"
                return 0
            fi
            if [[ "$DRY_RUN" == true ]]; then
                echo "NOT FOUND (dry-run: continuing)"
                return 0
            fi
            echo "NOT FOUND after ${CI_ELAPSED}s"
            echo "  Warning: CI may not have run but source files were changed."
            echo "  Verify manually that no regressions were introduced."
            return 1
            ;;
        *)
            echo "FAIL ($CI_RESULT)"
            return 1
            ;;
    esac
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
        echo "Do not publish this release until CI is green."
    fi

    exit "$exit_code"
}

main() {
    local source_changes
    local exit_code=0

    parse_args "$@"
    validate_config
    print_header

    source_changes="$(source_change_count)"

    # Required gate: the release SHA must either have passing CI or contain no
    # source-affecting changes that would have triggered CI.
    wait_for_required_ci "$source_changes"
    if ! report_required_ci "$source_changes"; then
        exit_code=1
    fi

    # Advisory gate: performance validation is useful release context, but it
    # should not block signing/publishing by itself.
    report_perf_validation

    finish_preflight "$exit_code"
}

main "$@"
