# Phase 1 — Explore

Black-box heuristic testing. You drive the app as a user would, applying oracle heuristics, and capture evidence for every finding.

## Preconditions

- Phase 0 Scope Report produced (or skipped explicitly on `main`).
- Dev server reachable. Prefer starting it yourself:
  ```bash
  cd web && DEV_BYPASS_AUTH=1 MOCK_AGENT=1 pnpm exec next dev -p 4000
  ```
  Then set `PLAYWRIGHT_BASE_URL=http://localhost:4000 PLAYWRIGHT_SKIP_WEB_SERVER=1` for any Playwright runs.
- `web/tests/LEDGER.md` read, uncovered behaviors noted.

## Black-box rule

During Phase 1 do NOT Read or Grep `web/src/app/**` or `web/src/lib/**`. You are a user. Allowed reads: `web/tests/LEDGER.md`, `web/e2e/**`, `web/docs/**`, `README.md`, `AGENTS.md`, `CLAUDE.md`.

## Procedure

1. **Pick scope from Phase 0's P0/P1 list.** If no Phase 0 ran, use the explicit area the caller gave (`/qa explore landing`).
2. **For each surface**, drive the app via Playwright MCP or `web/scripts/qa-probe.mjs`:
   - Set viewport: 1440×900 (desktop) then 375×667 (mobile). Both are mandatory.
   - Apply **SFDIPOT**: Structure, Function, Data, Interfaces, Platform, Operations, Time. See `references/oracles.md`.
   - Apply **FEW HICCUPPS** oracles: History, Explainability, World, User expectation, Product consistency, Purpose, Statutes, Similar products.
   - For each page: take a screenshot, run `AxeBuilder({ page }).analyze()`, capture `page.accessibility.snapshot()`.
3. **Classify findings** as you go:
   - `[P0]` — user-blocking bug, crash, data loss, security.
   - `[P1]` — serious degradation, broken happy path for a subset.
   - `[gap]` — no bug, but an important behavior is not covered by the ledger.
   - `[nit]` — cosmetic.
4. **Write a finding.md per finding** under `output/qa-agent/<ISO-date>/<slug>/` containing:
   - What (one-liner).
   - Severity + severity rationale.
   - Steps to reproduce (numbered, user-visible).
   - Expected vs actual.
   - Oracle (which heuristic caught it).
   - Evidence links (screenshot, axe JSON, trace).

## Evidence layout

```
output/qa-agent/<ISO-date>/<slug>/
├── finding.md          # required
├── <page>.png          # screenshot at time of observation
├── <page>-axe.json     # axe-core output, full severity breakdown
└── trace.zip           # optional, if captured from Playwright
```

Use `QA_SLUG=<slug> QA_BASE_URL=http://localhost:4000 node web/scripts/qa-probe.mjs` to batch screenshots + axe across the URLs you visited.

## Exit conditions

- Every P0 finding written up with evidence.
- Every uncovered behavior you identified logged as a `[gap]` row candidate for `web/tests/LEDGER.md`.
- Dev server you started is stopped.
- Final report emitted (see SKILL.md § Output format).

## Scope control

If the caller scoped you to one area, stay there. Don't wander into adjacent routes just because they were easy to click to. Finish the ranked list first; if time remains, ask the caller whether to expand.

## What NOT to report as a finding

- Your own misunderstandings of the UI — those are bugs in your exploration, not in the app.
- Implementation differences from what you expected without an oracle — "I thought it would work differently" is not a finding.
- Issues in the dev-only fixtures (`e2e-*` seeded rows) — report only what a real user would see.

## Example finding

```markdown
# Finding: dashboard compose bar accepts empty submission on Enter

**Severity:** P1
**Page:** /dashboard/fairchild/workspaces (chat tab)
**Viewport:** 1440×900
**Oracle:** User expectation — "pressing Enter on empty textarea should not send"

## Steps to reproduce
1. Navigate to /dashboard/fairchild/workspaces (auth bypassed).
2. Click the compose textarea (should be autofocused).
3. Press Enter without typing.

## Expected
Nothing happens. Send button is disabled; Enter should no-op.

## Actual
A message with empty content is added to the timeline.

## Evidence
- empty-submit.png
- empty-submit-trace.zip
```
