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

echo "=== Release Preflight ==="
echo "SHA:  $SHA"
echo "Repo: $REPO"
echo ""

# Check a workflow's conclusion for a given SHA.
# Returns: "success", "failure", "neutral", "cancelled", "skipped",
#          "timed_out", "action_required", or "not_found"
check_workflow() {
    local workflow_name="$1"
    local conclusion
    conclusion=$(gh api \
        "repos/$REPO/commits/$SHA/check-runs" \
        --jq ".check_runs[] | select(.name == \"$workflow_name\") | .conclusion" \
        2>/dev/null | head -1)
    echo "${conclusion:-not_found}"
}

EXIT_CODE=0

# --- Required: build-and-test (CI) ---
echo -n "CI (build-and-test): "
CI_RESULT=$(check_workflow "build-and-test")
case "$CI_RESULT" in
    success)
        echo "PASS"
        ;;
    not_found)
        # Release commits typically only touch CHANGELOG.md and don't trigger CI.
        # Check if the commit contains any source changes that would need CI.
        SOURCE_CHANGES=$(gh api "repos/$REPO/commits/$SHA" \
            --jq '[.files[].filename | select(
                startswith("Sources/") or
                startswith("Tests/") or
                startswith("scripts/build") or
                startswith("scripts/release") or
                startswith("scripts/notarize") or
                . == "Package.swift"
            )] | length' 2>/dev/null || echo "unknown")
        if [[ "$SOURCE_CHANGES" == "0" ]]; then
            echo "SKIPPED (no source changes in commit)"
        elif [[ "$DRY_RUN" == true ]]; then
            echo "NOT FOUND (dry-run: continuing)"
        else
            echo "NOT FOUND"
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
PERF_RESULT=$(check_workflow "capture")
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
