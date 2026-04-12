# Project setup for qa-web

What must be in place for this skill to work. `scripts/doctor.sh` checks each item; this file is the remediation source.

## Required project state

| Item | What | How to add |
|---|---|---|
| Playwright installed | `@playwright/test` in `web/package.json` | `cd web && pnpm add -D @playwright/test` |
| axe-core installed | `@axe-core/playwright` in `web/package.json` | `cd web && pnpm add -D @axe-core/playwright` |
| Browsers installed | Playwright Chromium binary | `cd web && pnpm exec playwright install chromium` |
| `qa-explore` project | Named project in `web/playwright.config.ts` with `testMatch: "explore/**/*.spec.ts"` | See "Playwright config" below |
| Env-driven baseURL | `web/playwright.config.ts` reads `PLAYWRIGHT_BASE_URL` | See "Playwright config" below |
| Exploration dir | `web/e2e/explore/` with axe fixture and seed spec | See "Exploration directory" below |
| Spec dir | `web/specs/` with `README.md` | `mkdir -p web/specs && cp reference template` |
| Ledger | `web/tests/LEDGER.md` with at least one row | See "Ledger" below |
| Evidence root | `output/qa-agent/` (gitignored via `output/`) | `mkdir -p output/qa-agent` at runtime |
| Mise tasks | `web:e2e:explore`, `web:qa:*` in `web/.mise.toml` | See "mise tasks" below |
| Dev server can run with bypass | `DEV_BYPASS_AUTH=1 MOCK_AGENT=1 pnpm dev` starts Next on an available port | See "Running the dev server" below |
| `gh` authenticated | `gh auth status` reports logged-in | `gh auth login` |

## Playwright config

`web/playwright.config.ts` should have:

- `BASE_URL = process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:3000"` at the top.
- `SKIP_WEB_SERVER = process.env.PLAYWRIGHT_SKIP_WEB_SERVER === "1"` so qa-web can point at a pre-running server.
- A `qa-explore` project entry:
  ```ts
  {
    name: "qa-explore",
    testMatch: "explore/**/*.spec.ts",
    use: { ...devices["Desktop Chrome"], video: "on", trace: "on", viewport: { width: 1440, height: 900 } },
  }
  ```
- `webServer` conditional on `SKIP_WEB_SERVER` so external-server mode works.

## Exploration directory

`web/e2e/explore/axe-fixture.ts`:

```ts
import { test as base, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

export const test = base.extend<{ axe: (opts?: {...}) => Promise<...> }>({
  axe: async ({ page }, use) => {
    await use(async (options = {}) => {
      let builder = new AxeBuilder({ page });
      if (options.include) builder = builder.include(options.include);
      // ...
      const result = await builder.analyze();
      return {
        violations: result.violations,
        critical: result.violations.filter(v => v.impact === "critical").length,
        serious: result.violations.filter(v => v.impact === "serious").length,
      };
    });
  },
});
export { expect };
```

Plus a seed spec `web/e2e/explore/a11y-primary-pages.spec.ts` that asserts `critical === 0` on landing + dashboard.

## Ledger

`web/tests/LEDGER.md` is the coverage source of truth. It maps user-visible behaviors → tests → last-verified date. Seed it from the existing Playwright + Vitest suite; see existing file for format.

## mise tasks

Add to `web/.mise.toml`:

- `web:e2e:explore` → `pnpm exec playwright test --project=qa-explore --reporter=list`
- `web:qa:init-agents` → `pnpm exec playwright init-agents --loop=claude`. Scaffolds Playwright's agent-loop **instruction files** (not a runtime CLI). Run once per repo; commit the output. The generated files — typically under `.github/chatmodes/` or similar — are markdown prompts a Claude agent can follow as Planner/Generator/Healer. They are complementary to the qa-web skill, not required by it.
- `web:qa:codegen` → `pnpm exec playwright codegen --target=javascript <url>`. Interactive recorder that emits starter test code from user actions. Useful as a seed during Phase 2; clean up selectors per `references/locator-priority.md` before committing.

> Note: There is no `pnpm exec playwright agent ...` subcommand. Earlier versions of this file assumed one existed and referenced `web:qa:plan/generate/heal`; those tasks were removed because they would fail at runtime.

## Running the dev server

Playwright's `webServer` auto-starts `pnpm dev`, but can misbehave when port 3000 is occupied by a broken process. The qa-web skill prefers pointing at a pre-running server:

```bash
cd web
DEV_BYPASS_AUTH=1 MOCK_AGENT=1 pnpm exec next dev -p 4000
```

Then run Playwright with:

```bash
PLAYWRIGHT_BASE_URL=http://localhost:4000 PLAYWRIGHT_SKIP_WEB_SERVER=1 \
  pnpm exec playwright test --project=qa-explore
```

## Repo-root conventions relied on

- `scripts/evidence.sh` — screenshot + R2 upload. Auto-sources `.env` for `EVIDENCE_UPLOAD_TOKEN`.
- `output/` is gitignored, so `output/qa-agent/` can be created freely at runtime.
- `.claude/skills/qa-web/` exists (this file's home).
- `.claude/agents/qa-web-agent.md` (thin subagent wrapper, used for sandboxed runs).
- `.claude/commands/qa.md` (slash command → subagent or skill).

## What doctor does NOT check (manual verification)

- Database seed correctness (run `node web/scripts/dev-seed.js` if dashboard rendering looks wrong).
- `.env` has `EVIDENCE_UPLOAD_TOKEN` (not required for exploration; required to upload evidence for a PR).
- CI runner labels (only relevant for PR gating, not local QA).
