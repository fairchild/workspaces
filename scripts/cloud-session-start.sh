#!/usr/bin/env bash
# SessionStart hook for Claude Code cloud sessions; a no-op anywhere else. Installs the locked web
# dependencies and git hooks on the fresh clone, then reports into the session what is ready,
# what environment setup failed to provide, and what this Linux VM cannot do. It never fails, and
# every step is time-boxed so the report lands inside the hook's 300 s timeout.
set -u

[[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
state="${WORKSPACES_CLOUD_STATE:-/var/log/workspaces-cloud-setup}"
dotclaude_status="$HOME/.claude/cloud-bootstrap.status"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CI=1

main() {
  cd "$root" || return
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT

  install_web web-next >"$work/web-next" &
  install_web web >"$work/web" &
  wait

  {
    cat "$work/web-next" "$work/web"
    install_git_hooks
    report_setup_failures
    report_browser
    report_dotclaude
    report_limits
  } | as_session_context
}

install_web() {
  local dir="$1" output
  if output="$(cd "$dir" && timeout -k 5 200 pnpm install --frozen-lockfile --prefer-offline 2>&1)"; then
    echo "$dir dependencies: installed from the lockfile."
  else
    echo "$dir dependencies: pnpm install failed; end of its output:"
    last_bytes <<<"$output"
  fi
}

install_git_hooks() {
  if ! command -v mise >/dev/null 2>&1 || ! command -v prek >/dev/null 2>&1; then
    echo "Git hooks: not installed, because mise or prek is missing."
  elif ! timeout -k 5 30 ./scripts/setup --hooks-only >/dev/null 2>&1; then
    echo "Git hooks: scripts/setup --hooks-only failed."
  fi
}

report_setup_failures() {
  local outcome name took
  if [[ ! -f "$state/status" ]]; then
    echo "Environment setup: no record at $state/status, so whether its tools installed is unknown. Check that the environment's setup script runs scripts/cloud-environment.sh."
    return
  fi
  while read -r outcome name took; do
    if [[ "$outcome" == failed ]]; then
      echo "Environment setup: $name failed after $took; end of $state/$name.log:"
      last_bytes <"$state/$name.log" 2>/dev/null
    fi
  done <"$state/status"
}

report_browser() {
  if browsers_installed; then
    echo "Playwright: web-next's pinned browser is installed."
  else
    echo "Playwright: web-next's pinned browser is not installed, so e2e tests can't run. Either setup failed or the environment's cache predates the pin; a rebuild fixes both. Don't run playwright install."
  fi
}

browsers_installed() {
  local locations location
  locations="$(cd web-next && timeout -k 5 20 pnpm exec playwright install --dry-run chromium 2>/dev/null \
    | sed -n 's/^ *Install location: *//p')"
  [[ -n "$locations" ]] || return 1
  while read -r location; do
    [[ -d "$location" ]] || return 1
  done <<<"$locations"
}

report_dotclaude() {
  if [[ -f "$dotclaude_status" ]]; then
    echo "Owner's dotclaude config: $(last_bytes <"$dotclaude_status")"
  else
    echo "Owner's dotclaude config: not installed, so personal instructions and skills are absent."
  fi
}

report_limits() {
  echo "This VM is Linux, so swift build, swift test and app UI capture can't run here. swift-format can: run mise run lint before pushing Swift. For compile and test results, push the branch and read the macOS CI run."
  echo "gh pr and gh issue fail here because GitHub's GraphQL API is blocked. Use the built-in GitHub tools, or gh api repos/fairchild/workspaces/... for REST."
  echo "Details: docs/development/remote-sessions.md."
}

last_bytes() {
  tail -c 800
}

as_session_context() {
  jq -Rsc '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: rtrimstr("\n")}}'
}

main
exit 0
