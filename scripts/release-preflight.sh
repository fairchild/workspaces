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
#   - perf-validation passing is advisory                 → warning only
#
# Exit codes:
#   0  all required checks passed
#   1  a required check failed or was not found

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

SHA="${1:?Usage: release-preflight.sh [--dry-run] <sha> [repo]}"
REPO="${2:-${GITHUB_REPOSITORY:-fairchild/workspaces}}"
POLL_SECONDS="${RELEASE_PREFLIGHT_POLL_SECONDS:-15}"
TIMEOUT_SECONDS="${RELEASE_PREFLIGHT_TIMEOUT_SECONDS:-900}"

if ! [[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] || (( POLL_SECONDS < 1 )); then
    echo "RELEASE_PREFLIGHT_POLL_SECONDS must be a positive integer" >&2
    exit 2
fi
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "RELEASE_PREFLIGHT_TIMEOUT_SECONDS must be a non-negative integer" >&2
    exit 2
fi

echo "=== Release Preflight ==="
echo "SHA:  $SHA"
echo "Repo: $REPO"
echo ""

# Check a check-run's state for a given SHA.
# Returns a terminal conclusion, "queued", "in_progress", or "not_found".
check_workflow_state() {
    local workflow_name="$1"
    local state
    state=$(gh api \
        "repos/$REPO/commits/$SHA/check-runs" \
        --jq ".check_runs | map(select(.name == \"$workflow_name\")) | sort_by(.started_at // .created_at // \"\") | last | if . == null then empty elif .status == \"completed\" then .conclusion else .status end" \
        2>/dev/null)
    echo "${state:-not_found}"
}

check_any_workflow() {
    local workflow_name=""
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

source_change_count() {
    gh api "repos/$REPO/commits/$SHA" \
        --jq '[.files[].filename | select(
            . == ".github/workflows/ci.yml" or
            . == ".github/workflows/ci-fallback.yml" or
            . == ".github/workflows/release.yml" or
            . == ".swift-format" or
            . == "Package.swift" or
            . == "Package.resolved" or
            . == "WorkspaceManager.entitlements" or
            startswith("Sources/") or
            startswith("Tests/") or
            . == "scripts/build-ghosttykit.sh" or
            . == "scripts/build-release.sh" or
            . == "scripts/generate-sparkle-appcast.sh" or
            . == "scripts/install-local.sh" or
            . == "scripts/notarize.sh" or
            . == "scripts/prepare-release.sh" or
            . == "scripts/release-preflight.sh" or
            . == "scripts/release-version.sh" or
            . == "scripts/setup-release-secrets.sh" or
            . == "scripts/verify-app-keychain-signing.sh" or
            . == "scripts/verify-installed-perf.sh" or
            . == "scripts/verify-p12.sh" or
            . == "scripts/verify-release-bundle.sh"
        )] | length' 2>/dev/null || echo "unknown"
}

EXIT_CODE=0

# --- Required: build-and-test (CI) ---
echo -n "CI (build-and-test): "
SOURCE_CHANGES="$(source_change_count)"
CI_RESULT="not_found"
elapsed=0

while true; do
    CI_RESULT=$(check_workflow_state "build-and-test")
    case "$CI_RESULT" in
        queued|in_progress|not_found)
            if [[ "$SOURCE_CHANGES" == "0" && "$CI_RESULT" == "not_found" ]]; then
                break
            fi
            if [[ "$DRY_RUN" == true ]]; then
                break
            fi
            if (( elapsed >= TIMEOUT_SECONDS )); then
                break
            fi
            echo "${CI_RESULT}; waiting ${POLL_SECONDS}s"
            sleep "$POLL_SECONDS"
            elapsed=$((elapsed + POLL_SECONDS))
            echo -n "CI (build-and-test): "
            ;;
        *)
            break
            ;;
    esac
done

case "$CI_RESULT" in
    success)
        echo "PASS"
        ;;
    queued|in_progress)
        if [[ "$DRY_RUN" == true ]]; then
            echo "${CI_RESULT} (dry-run: continuing)"
        else
            echo "TIMEOUT ($CI_RESULT after ${elapsed}s)"
            EXIT_CODE=1
        fi
        ;;
    not_found)
        # Release commits typically only touch CHANGELOG.md and don't trigger CI.
        # Check if the commit contains any source changes that would need CI.
        if [[ "$SOURCE_CHANGES" == "0" ]]; then
            echo "SKIPPED (no source changes in commit)"
        elif [[ "$DRY_RUN" == true ]]; then
            echo "NOT FOUND (dry-run: continuing)"
        else
            echo "NOT FOUND after ${elapsed}s"
            echo "  Warning: CI may not have run but source files were changed."
            echo "  Verify manually that no regressions were introduced."
            EXIT_CODE=1
        fi
        ;;
    *)
        echo "FAIL ($CI_RESULT)"
        EXIT_CODE=1
        ;;
esac

# --- Advisory: perf-validation ---
echo -n "Perf validation: "
PERF_RESULT=$(check_any_workflow "perf-validation" "capture")
case "$PERF_RESULT" in
    success)
        echo "PASS"
        ;;
    not_found)
        echo "NOT FOUND (advisory — perf may not have run on this SHA)"
        ;;
    *)
        echo "WARN ($PERF_RESULT) — perf regression detected but not blocking release"
        ;;
esac

echo ""
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "Preflight passed."
else
    echo "Preflight FAILED — required checks did not pass on $SHA."
    echo "Do not publish this release until CI is green."
fi

exit "$EXIT_CODE"
