#!/usr/bin/env bash
# qa-web doctor: verifies the project is configured for the qa-web skill.
# Exit 0 = ready. Exit 1 = fix required. See references/doctor.md + references/setup.md.

set -uo pipefail

ok=0; fail=0; warn=0
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

check_ok()   { printf "✓ %s\n" "$1"; ok=$((ok+1)); }
check_fail() { printf "✗ %s — %s\n" "$1" "$2"; fail=$((fail+1)); }
check_warn() { printf "⚠ %s — %s\n" "$1" "$2"; warn=$((warn+1)); }

# 1. repo root resolvable
if [[ -z "$REPO_ROOT" ]]; then
  echo "✗ repo root resolvable — run doctor from inside a git repo"
  exit 1
fi
check_ok "repo root resolvable"

cd "$REPO_ROOT"

# 2. web/ present
if [[ -f web/package.json ]]; then check_ok "web/ present"
else check_fail "web/ present" "this repo has no web/ dir — wrong project?"; fi

# 3. @playwright/test
if [[ -f web/node_modules/@playwright/test/package.json ]]; then check_ok "@playwright/test installed"
else check_fail "@playwright/test installed" "cd web && pnpm add -D @playwright/test (setup.md § Required project state)"; fi

# 4. @axe-core/playwright
if [[ -f web/node_modules/@axe-core/playwright/package.json ]]; then check_ok "@axe-core/playwright installed"
else check_fail "@axe-core/playwright installed" "cd web && pnpm add -D @axe-core/playwright (setup.md)"; fi

# 5. Playwright browsers
if (cd web && pnpm exec playwright --version >/dev/null 2>&1); then
  check_ok "Playwright CLI resolvable"
else
  check_fail "Playwright CLI resolvable" "cd web && pnpm exec playwright install chromium (setup.md)"
fi

# 6. qa-explore project
if grep -q 'name: *"qa-explore"' web/playwright.config.ts 2>/dev/null; then check_ok "qa-explore project declared"
else check_fail "qa-explore project declared" "add a projects[] entry (setup.md § Playwright config)"; fi

# 7. env-driven baseURL
if grep -q "PLAYWRIGHT_BASE_URL" web/playwright.config.ts 2>/dev/null; then check_ok "PLAYWRIGHT_BASE_URL supported"
else check_fail "PLAYWRIGHT_BASE_URL supported" "make baseURL env-driven (setup.md § Playwright config)"; fi

# 8. exploration fixture + spec
if [[ -f web/e2e/explore/axe-fixture.ts ]] && ls web/e2e/explore/*.spec.ts >/dev/null 2>&1; then
  check_ok "exploration fixture + spec present"
else
  check_fail "exploration fixture + spec present" "setup.md § Exploration directory"
fi

# 9. specs scaffolded
if [[ -f web/specs/README.md ]]; then check_ok "web/specs/ scaffolded"
else check_fail "web/specs/ scaffolded" "mkdir web/specs and add README (setup.md)"; fi

# 10. LEDGER present with rows
if [[ -f web/tests/LEDGER.md ]] && grep -q "^|" web/tests/LEDGER.md; then check_ok "LEDGER present with rows"
else check_fail "LEDGER present with rows" "seed web/tests/LEDGER.md (setup.md § Ledger)"; fi

# 11. mise qa tasks
if grep -q 'web:e2e:explore' web/.mise.toml 2>/dev/null \
   && grep -q 'web:qa:init-agents' web/.mise.toml 2>/dev/null \
   && grep -q 'web:qa:codegen' web/.mise.toml 2>/dev/null; then
  check_ok "mise qa tasks present"
else
  check_fail "mise qa tasks present" "ensure web:e2e:explore, web:qa:init-agents, and web:qa:codegen are in web/.mise.toml (setup.md § mise tasks)"
fi

# 12. Chromium browser installed (filesystem check; cross-platform-ish)
PLAYWRIGHT_CACHE="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/Library/Caches/ms-playwright}"
[[ -d "$PLAYWRIGHT_CACHE" ]] || PLAYWRIGHT_CACHE="$HOME/.cache/ms-playwright"
if ls "$PLAYWRIGHT_CACHE"/chromium-* >/dev/null 2>&1 \
   || ls "$PLAYWRIGHT_CACHE"/chromium_headless_shell-* >/dev/null 2>&1; then
  check_ok "Chromium browser installed"
else
  check_fail "Chromium browser installed" "cd web && pnpm exec playwright install chromium (setup.md § Required project state)"
fi

# 13. gh auth (warn-only)
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then check_ok "gh authenticated"
else check_warn "gh authenticated" "run 'gh auth login' to enable Phase 0 PR queries (optional)"; fi

# 14. qa-probe script
if [[ -f web/scripts/qa-probe.js ]]; then check_ok "qa-probe script present"
else check_fail "qa-probe script present" "copy from skill template (setup.md)"; fi

# 15. Playwright agents scaffolded (optional but enables delegated Author/Heal)
if [[ -f web/.claude/agents/playwright-test-planner.md \
    && -f web/.claude/agents/playwright-test-generator.md \
    && -f web/.claude/agents/playwright-test-healer.md \
    && -f web/.mcp.json ]]; then
  check_ok "Playwright agents scaffolded"
else
  check_warn "Playwright agents scaffolded" "run 'cd web && pnpm exec playwright init-agents --loop=claude' to enable Phase 2/3 delegation (fallbacks work without it)"
fi

echo "doctor: $ok ok, $fail failed, $warn warned"
[[ $fail -gt 0 ]] && exit 1 || exit 0
