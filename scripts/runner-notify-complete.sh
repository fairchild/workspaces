#!/bin/bash
# GitHub Actions runner hook: called when a job completes.
# Set ACTIONS_RUNNER_HOOK_JOB_COMPLETED to point at an installed copy of this script.
#
# The hook cannot know whether the job passed. Job status reaches a runner only
# through the API — it is absent from the hook environment, by design:
# https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/run-scripts
# So this line records the job's identity, not its outcome: END (the job
# stopped) plus the run id and attempt, which scripts/runners.py resolves
# against GitHub when it renders. The word here used to be DONE, and a failed
# v0.24.0 release was read as a passing one because of it.
#
# SAFETY: This script must NEVER exit non-zero — a failing hook fails the CI job.
# All work is wrapped in a subshell with || true, and we exit 0 unconditionally.

(
    sanitize() { printf '%s' "$1" | tr -d '"\\|'; }

    repo="$(sanitize "${GITHUB_REPOSITORY##*/}")"
    job="$(sanitize "${GITHUB_JOB:-unknown}")"
    workflow="$(sanitize "${GITHUB_WORKFLOW:-CI}")"
    ref="$(sanitize "${GITHUB_REF_NAME:-?}")"
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Identity of the run to ask about later. Attempt is recorded only when it
    # is a re-run: the run-level conclusion reports the newest attempt, so an
    # older attempt's line would otherwise inherit a verdict it never earned.
    run=""
    [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]] && run="  run=${GITHUB_RUN_ID}"
    [[ -n "$run" && "${GITHUB_RUN_ATTEMPT:-1}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-1}" -gt 1 ]] &&
        run="${run}  attempt=${GITHUB_RUN_ATTEMPT}"

    log="$HOME/.local/share/runner-activity.log"
    mkdir -p "$(dirname "$log")"
    printf '%s  END    %-14s  %s/%s  %s%s\n' "$ts" "$repo" "$workflow" "$job" "$ref" "$run" >> "$log"
) >/dev/null 2>&1 || true

exit 0
