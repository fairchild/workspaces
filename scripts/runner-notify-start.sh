#!/bin/bash
# GitHub Actions runner hook: called when a job starts.
# Set ACTIONS_RUNNER_HOOK_JOB_STARTED to point at an installed copy of this script.
#
# SAFETY: This script must NEVER exit non-zero — a failing hook fails the CI job.
# All work is wrapped in a subshell with || true, and we exit 0 unconditionally.

(
    sanitize() { printf '%s' "$1" | tr -d '"\\'; }

    repo="$(sanitize "${GITHUB_REPOSITORY##*/}")"
    job="$(sanitize "${GITHUB_JOB:-unknown}")"
    workflow="$(sanitize "${GITHUB_WORKFLOW:-CI}")"
    ref="$(sanitize "${GITHUB_REF_NAME:-?}")"
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    log="$HOME/.local/share/runner-activity.log"
    mkdir -p "$(dirname "$log")"
    printf '%s  START  %-14s  %s/%s  %s\n' "$ts" "$repo" "$workflow" "$job" "$ref" >> "$log"
) >/dev/null 2>&1 || true

exit 0
