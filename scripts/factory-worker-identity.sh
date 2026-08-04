#!/usr/bin/env bash
# Wires the current worktree's git/gh identity to the workspaces-factory App
# when FACTORY_WORKER_IDENTITY=app (issue #1180): pushes and `gh pr create`
# go out as workspaces-factory[bot] instead of the worker's ambient owner
# `gh` auth, so the owner can formally approve the resulting PR (GitHub
# blocks approving your own PR). Unset (the default) or any other value:
# no-op — nothing about the worker's identity changes.
#
# Deliberately does NOT `set -u`/`set -o pipefail`: this file is meant to be
# `source`d into an arbitrary caller's shell, and those options are
# shell-wide, not scoped to a sourced file — turning them on here would leak
# into the rest of the worker's session even on the no-op path. Every
# variable read below is already defaulted (${VAR:-}) so nounset isn't
# needed for safety, and every command whose failure matters is checked
# explicitly instead of relying on pipefail.
#
# Source this so the exported GH_TOKEN survives in the calling shell:
#   source scripts/factory-worker-identity.sh
# Running it instead of sourcing it still leaves the local git config (commit
# identity, credential helper) wired, but GH_TOKEN only lives in the
# subshell and won't reach your interactive shell or `gh`.

# `return` (not a function wrapping it — a function's `return` only exits the
# function, not this sourced file) so a no-op stays a no-op whether this file
# is sourced or executed.
if [[ "${FACTORY_WORKER_IDENTITY:-}" != "app" ]]; then
  return 0 2>/dev/null || exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
BOT_LOGIN="workspaces-factory[bot]"
# GitHub only associates a bot commit with its App account via the numeric
# ID-prefixed noreply address (see docs/development/github-app-identities.md
# § Repeating The Contributor Setup, step 3-4); that ID isn't known until
# Michael creates the App. This fallback is a valid, syntactically-correct
# email that won't link to the bot's profile until FACTORY_WORKER_BOT_EMAIL
# is set to the ID-prefixed form — PR *authorship* (the actual fix) comes
# from the App token, not this commit email, so the fallback is safe to ship
# unset, just cosmetically incomplete.
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
#
# Each command's exit status is checked individually rather than trusting
# pipefail/errexit (deliberately unset above): a partial failure here (e.g.
# a locked or read-only .git/config) must not report success while leaving
# GH_TOKEN exported against a stale owner commit/push identity.
if ! git -C "$REPO_ROOT" config user.name "$BOT_LOGIN" \
  || ! git -C "$REPO_ROOT" config user.email "$BOT_EMAIL" \
  || ! git -C "$REPO_ROOT" config credential.https://github.com.helper "" \
  || ! git -C "$REPO_ROOT" config --add credential.https://github.com.helper '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'; then
  echo "factory-worker-identity: FACTORY_WORKER_IDENTITY=app is set and a token was minted, but wiring local git config in $REPO_ROOT failed (read-only or locked .git/config?)." >&2
  echo "factory-worker-identity: GH_TOKEN is NOT exported to avoid pairing bot gh auth with a stale owner commit/push identity — fix the git config issue and re-source." >&2
  unset GH_TOKEN
  return 1 2>/dev/null || exit 1
fi

echo "factory-worker-identity: configured as $BOT_LOGIN (GH_TOKEN set, local git identity + credential helper wired)" >&2

# The credential helper override is written to .git/config and outlives this
# shell. A later `git push` in this same worktree from a shell that never
# sourced this script (GH_TOKEN unset) sees an empty password and fails
# closed rather than silently falling back to the owner's keychain
# credentials — that's the intended failure mode, but it means re-sourcing
# this script (or restoring `credential.https://github.com.helper` to
# `osxkeychain`) is required to go back to pushing as the owner in the same
# worktree. Fresh worker worktrees per dispatch sidestep this entirely.
