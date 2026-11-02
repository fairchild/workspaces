#!/usr/bin/env bash
# SessionStart hook for Claude Code cloud sessions; a no-op anywhere else. Installs the locked web
# dependencies and git hooks on the fresh clone, then tells the session what is ready, what setup
# failed to provide, and what this environment cannot do.
#
# Synchronous, so tests work from the agent's first command, and it never fails: a problem here
# belongs in the session's context, not in a session that won't start.
set -u

[[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root" || exit 0

state="${WORKSPACES_CLOUD_STATE:-/var/log/workspaces-cloud-setup}"
dotclaude_status="$HOME/.claude/cloud-bootstrap.status"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CI=1

lines=()

# pnpm decides what is current: setup's pnpm fetch leaves a node_modules that holds no tools, so
# its presence says nothing, and an install with nothing to do takes seconds.
install_web() {
  local dir="$1" output
  if output="$(cd "$dir" && timeout 200 pnpm install --frozen-lockfile --prefer-offline 2>&1)"; then
    lines+=("$dir dependencies: installed from the lockfile.")
  else
    lines+=("$dir dependencies: pnpm install failed; last lines:" "$(tail -n 10 <<<"$output")")
  fi
}

report_setup() {
  local outcome name took
  if [[ ! -f "$state/status" ]]; then
    lines+=("Environment setup: no record at $state/status, so whether its tools installed is unknown. Check that the environment's setup script runs scripts/cloud-environment.sh.")
    return
  fi
  while read -r outcome name took; do
    if [[ "$outcome" == failed ]]; then
      lines+=("Environment setup: $name failed after $took; last lines of $state/$name.log:" "$(tail -n 5 "$state/$name.log" 2>/dev/null)")
    fi
  done <"$state/status"
}

report_browser() {
  local check='const fs = require("node:fs"); const { chromium } = require("@playwright/test"); process.exit(fs.existsSync(chromium.executablePath()) ? 0 : 1)'
  if (cd web-next && node -e "$check") >/dev/null 2>&1; then
    lines+=("Playwright: web-next's pinned browser is installed.")
  else
    lines+=("Playwright: web-next's pinned browser is not installed, so e2e tests can't run. Either setup failed or the environment's cache predates the pin; a rebuild fixes both. Don't run playwright install.")
  fi
}

report_dotclaude() {
  if [[ -f "$dotclaude_status" ]]; then
    lines+=("Owner's dotclaude config: $(cat "$dotclaude_status")")
  else
    lines+=("Owner's dotclaude config: not installed, so personal instructions and skills are absent.")
  fi
}

install_web web-next
install_web web

if command -v mise >/dev/null 2>&1 && command -v prek >/dev/null 2>&1; then
  ./scripts/setup --hooks-only >/dev/null 2>&1 || lines+=("Git hooks: scripts/setup --hooks-only failed.")
else
  lines+=("Git hooks: not installed, because mise or prek is missing.")
fi

report_setup
report_browser
report_dotclaude

lines+=(
  "This VM is Linux, so swift build, swift test and app UI capture can't run here. swift-format can: run mise run lint before pushing Swift. For compile and test results, push the branch and read the macOS CI run."
  "gh pr and gh issue fail here because GitHub's GraphQL API is blocked. Use the built-in GitHub tools, or gh api repos/fairchild/workspaces/... for REST."
  "Details: docs/development/remote-sessions.md."
)

python3 -c '
import json
import sys

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "\n".join(sys.argv[1:]),
}}))
' "${lines[@]}"
exit 0
