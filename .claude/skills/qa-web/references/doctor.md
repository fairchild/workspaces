# Doctor — setup verification

The `scripts/doctor.sh` script enforces this checklist. If any check fails, the doctor exits non-zero with a remediation hint pointing to `references/setup.md`.

## Checks, in order

Each check is a single assertion. Order is chosen to fail fast on the most common breakage.

1. **Repo root resolvable** — `git rev-parse --show-toplevel` succeeds and points at a dir that contains `web/` and `.claude/skills/qa-web/`. Fail if script is run outside the repo.
2. **`web/` exists** — `web/package.json` present.
3. **Playwright installed** — `web/node_modules/@playwright/test/package.json` exists.
4. **axe-core installed** — `web/node_modules/@axe-core/playwright/package.json` exists.
5. **Browsers installed** — `pnpm exec playwright --version` succeeds and a Chromium binary is resolvable via `pnpm exec playwright install --dry-run chromium`.
6. **`qa-explore` project declared** — grep `name: "qa-explore"` in `web/playwright.config.ts`.
7. **Env-driven baseURL** — grep `PLAYWRIGHT_BASE_URL` in `web/playwright.config.ts`.
8. **Exploration dir present** — `web/e2e/explore/axe-fixture.ts` and at least one `*.spec.ts`.
9. **Specs dir** — `web/specs/README.md` exists.
10. **Ledger exists** — `web/tests/LEDGER.md` exists and has at least one table row.
11. **Mise tasks present** — grep `web:e2e:explore`, `web:qa:init-agents`, `web:qa:codegen` in `web/.mise.toml`.
12. **Chromium browser installed** — filesystem check for `chromium-*` under `$PLAYWRIGHT_BROWSERS_PATH` (falls back to `~/Library/Caches/ms-playwright` on macOS, `~/.cache/ms-playwright` on Linux).
13. **`gh` available and authenticated** — `gh auth status` exits 0. Warn (not fail) if unauthenticated — Phase 0 PR queries need it but Phases 1–3 don't.
14. **qa-probe script present** — `web/scripts/qa-probe.mjs` exists.

## Severity

- **FAIL** (exit 1): 1–12, 14. The skill cannot run without these.
- **WARN** (exit 0, print hint): 13. Optional for local Explore-only runs.

## Output format

Each check prints one line:

```
✓ <check name>
✗ <check name> — <one-line remediation pointing to references/setup.md § <section>>
⚠ <check name> — <one-line warning>
```

End with a summary:

```
doctor: <N> ok, <F> failed, <W> warned
```

If any FAIL, exit 1. Otherwise exit 0.

## Example output (healthy)

```
✓ repo root resolvable
✓ web/ present
✓ @playwright/test installed
✓ @axe-core/playwright installed
✓ Playwright browsers installed
✓ qa-explore project declared
✓ PLAYWRIGHT_BASE_URL supported
✓ exploration fixture + spec present
✓ web/specs/ scaffolded
✓ LEDGER present with rows
✓ mise qa tasks present
✓ gh authenticated
✓ qa-probe script present
doctor: 13 ok, 0 failed, 0 warned
```

## Example output (failing)

```
✓ repo root resolvable
✓ web/ present
✗ @axe-core/playwright installed — run `cd web && pnpm add -D @axe-core/playwright` (setup.md § Required project state)
✓ @playwright/test installed
⚠ gh authenticated — run `gh auth login` to enable Phase 0 PR queries (setup.md § gh)
doctor: 11 ok, 1 failed, 1 warned
```
