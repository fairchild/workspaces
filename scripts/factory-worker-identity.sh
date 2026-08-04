#!/usr/bin/env bash
# Wires the current worktree's git/gh identity to the workspaces-factory App
# when FACTORY_WORKER_IDENTITY=app (issue #1180): pushes and `gh pr create`
# go out as workspaces-factory[bot] instead of the worker's ambient owner
# `gh` auth, so the owner can formally approve the resulting PR (GitHub
# blocks approving your own PR). Unset (the default) or any other value:
# no-op — nothing about the worker's identity changes.
#
# Source this so the exported GH_TOKEN survives in the calling shell:
#   source scripts/factory-worker-identity.sh
# Running it instead of sourcing it still leaves the local git config (commit
# identity, credential helper) wired, but GH_TOKEN only lives in the
# subshell and won't reach your interactive shell or `gh`.
set -uo pipefail

# `return` (not a function wrapping it — a function's `return` only exits the
# function, not this sourced file) so a no-op stays a no-op whether this file
# is sourced or executed.
if [[ "${FACTORY_WORKER_IDENTITY:-}" != "app" ]]; then
  return 0 2>/dev/null || exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
BOT_LOGIN="workspaces-factory[bot]"
BOT_EMAIL="${FACTORY_WORKER_BOT_EMAIL:-workspaces-factory[bot]@users.noreply.github.com}"

TOKEN="$(uv run --script "$REPO_ROOT/scripts/factory-worker-token.py")"
STATUS=$?
if [[ $STATUS -ne 0 || -z "$TOKEN" ]]; then
  echo "factory-worker-identity: FACTORY_WORKER_IDENTITY=app is set but minting a workspaces-factory token failed." >&2
  echo "factory-worker-identity: run 'uv run --script scripts/factory-worker-token.py --check' to see why." >&2
  return 1 2>/dev/null || exit 1
fi

export GH_TOKEN="$TOKEN"

# Local-repo scope only — never touches global git config. The credential
# helper reads GH_TOKEN live from the environment at fill time, so the token
# itself never lands on disk (contrast scripts/factory-cost-append.py's
# embedded-URL pattern, which is fine for a throwaway CI checkout but not for
# a worktree that persists for the life of the session).
git -C "$REPO_ROOT" config user.name "$BOT_LOGIN"
git -C "$REPO_ROOT" config user.email "$BOT_EMAIL"
git -C "$REPO_ROOT" config credential.https://github.com.helper ""
git -C "$REPO_ROOT" config --add credential.https://github.com.helper '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'

echo "factory-worker-identity: configured as $BOT_LOGIN (GH_TOKEN set, local git identity + credential helper wired)" >&2
