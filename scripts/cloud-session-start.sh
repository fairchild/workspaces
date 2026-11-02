#!/usr/bin/env bash
# SessionStart hook for Claude Code cloud sessions; a no-op anywhere else. Installs the locked web
# dependencies and git hooks on the fresh clone, then tells the session what is ready, what setup
# failed to provide, and what this environment cannot do.
#
# Synchronous, so tests work from the agent's first command, and it never fails: a problem here
# belongs in the session's context, not in a session that won't start. Every step has a time
# limit that keeps the whole hook inside the 300 s timeout in .claude/settings.json, because the
# report only reaches the session if the hook finishes.
set -u

[[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root" || exit 0

state="${WORKSPACES_CLOUD_STATE:-/var/log/workspaces-cloud-setup}"
dotclaude_status="$HOME/.claude/cloud-bootstrap.status"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CI=1

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# A log tail goes by bytes, not lines: one line of a failed install can run to megabytes.
log_tail() { tail -c 800; }

# pnpm decides what is current: setup's pnpm fetch leaves a node_modules that holds no tools, so
# its presence says nothing, and an install with nothing to do takes seconds.
install_web() {
  local dir="$1" output
  if output="$(cd "$dir" && timeout -k 5 200 pnpm install --frozen-lockfile --prefer-offline 2>&1)"; then
    echo "$dir dependencies: installed from the lockfile."
  else
    echo "$dir dependencies: pnpm install failed; end of its output:"
    log_tail <<<"$output"
  fi
}

install_hooks() {
  if ! command -v mise >/dev/null 2>&1 || ! command -v prek >/dev/null 2>&1; then
    echo "Git hooks: not installed, because mise or prek is missing."
  elif ! timeout -k 5 30 ./scripts/setup --hooks-only >/dev/null 2>&1; then
    echo "Git hooks: scripts/setup --hooks-only failed."
  fi
}

report_setup() {
  local outcome name took
  if [[ ! -f "$state/status" ]]; then
    echo "Environment setup: no record at $state/status, so whether its tools installed is unknown. Check that the environment's setup script runs scripts/cloud-environment.sh."
    return
  fi
  while read -r outcome name took; do
    if [[ "$outcome" == failed ]]; then
      echo "Environment setup: $name failed after $took; end of $state/$name.log:"
      log_tail <"$state/$name.log" 2>/dev/null
    fi
  done <"$state/status"
}

report_browser() {
  local check='const fs = require("node:fs"); const { chromium } = require("@playwright/test"); process.exit(fs.existsSync(chromium.executablePath()) ? 0 : 1)'
  if (cd web-next && timeout -k 5 20 node -e "$check") >/dev/null 2>&1; then
    echo "Playwright: web-next's pinned browser is installed."
  else
    echo "Playwright: web-next's pinned browser is not installed, so e2e tests can't run. Either setup failed or the environment's cache predates the pin; a rebuild fixes both. Don't run playwright install."
  fi
}

report_dotclaude() {
  if [[ -f "$dotclaude_status" ]]; then
    echo "Owner's dotclaude config: $(log_tail <"$dotclaude_status")"
  else
    echo "Owner's dotclaude config: not installed, so personal instructions and skills are absent."
  fi
}

report_limits() {
  echo "This VM is Linux, so swift build, swift test and app UI capture can't run here. swift-format can: run mise run lint before pushing Swift. For compile and test results, push the branch and read the macOS CI run."
  echo "gh pr and gh issue fail here because GitHub's GraphQL API is blocked. Use the built-in GitHub tools, or gh api repos/fairchild/workspaces/... for REST."
  echo "Details: docs/development/remote-sessions.md."
}

install_web web-next >"$work/web-next" &
install_web web >"$work/web" &
wait

{
  cat "$work/web-next" "$work/web"
  install_hooks
  report_setup
  report_browser
  report_dotclaude
  report_limits
} | python3 -c '
import json
import sys

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": sys.stdin.read().strip(),
}}))
'
exit 0
