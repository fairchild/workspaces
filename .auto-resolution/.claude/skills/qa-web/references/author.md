# Phase 2 — Author

Convert findings and uncovered behaviors into durable, spec-first tests. You orchestrate the flow; delegate test-code generation to Playwright's Generator subagent.

## Preconditions

- A Phase 1 finding you want to lock in, OR a specific `[gap]` row from `web/tests/LEDGER.md`, OR a pre-written spec the caller handed you.
- Doctor passing. Dev server reachable.
- `web/.claude/agents/playwright-test-generator.md` exists (created by `mise run web:qa:init-agents`). Doctor check #15 enforces this.

## Procedure

1. **Write the spec.** Create `web/specs/<slug>.md` using the template in `references/spec-template.md`. State the behavior in the imperative — what the user can do or observe — and the oracle — how you know it's correct. Do not write the test code yet.
2. **Pause for human approval.** Print the spec path and ask the caller to review. Expected feedback: wrong oracle, missing negative case, wrong layer (e.g. "this should be integration, not E2E").
3. **Generate the test via the Playwright Generator subagent.** After approval, invoke the Agent tool:
   ```
   Agent({
     subagent_type: "playwright-test-generator",
     description: "Generate <slug> test from spec",
     prompt: "Read web/specs/<slug>.md and generate the Playwright test.\n\n<test-suite>...</test-suite>\n<test-name>...</test-name>\n<test-file>web/e2e/full/<slug>.spec.ts</test-file>\n<seed-file>web/e2e/seed.ts</seed-file>\n<body>...spec contents...</body>"
   })
   ```
   The generator uses the `playwright-test` MCP server to drive the live dev server, verify selectors, and emit typed test code. It runs in its own context window so generation artifacts don't pollute your thread.
4. **Iterate locally.** `pnpm exec playwright test web/e2e/full/<slug>.spec.ts`. Fix anything red. The Generator is competent but not infallible — review the output for:
   - Locator priority (see `references/locator-priority.md`) — prefer `getByRole` + accessible name over generated selectors.
   - Flakiness — if a retry needed a timing hack, replace with `expect(locator).toBeVisible({ timeout })` or `page.waitForRequest`.
5. **Full-suite smoke.** `mise run web:check && mise run web:e2e` to confirm no regression in the existing suite.
6. **Update the ledger.** Add a row to `web/tests/LEDGER.md`:
   ```
   | <behavior> | e2e-full | `full/<slug>.spec.ts :: <test name>` | <today ISO> | qa-web-agent |
   ```
   Remove any matching `[gap]` row.
7. **Stop — summarize, don't PR.** Print diff summary and evidence paths. Let the caller review and open the PR.

## Fallback: no Generator available

If the `playwright-test-generator` subagent is missing (doctor fails check #15), fall back to writing the test yourself using `web/scripts/qa-probe.js` or `mise run web:qa:codegen <url>` (interactive recorder) as seed material. Still follow locator-priority rules manually. Then tell the caller to run `mise run web:qa:init-agents` to enable the delegated path next time.

## When to refuse

Refuse to write the spec if:

- The only place the behavior is documented is the implementation (`web/src/**`). That's a tautology in the making. Tell the caller: "I can't write this spec — the current implementation is the only source of truth. Please state what the behavior *should* be."
- The requested test would cover something integration or unit tests already cover. Recommend promoting it down the trophy instead.
- The finding describes an implementation detail, not a user-visible behavior (e.g. "this function caches for 5 minutes"). Ask for a user-level oracle.

## Trophy shape guardrail

Before writing E2E:

- Could this be a **unit test** in `web/src/lib/__tests__/` hitting the pure function? Write it there.
- Could this be an **integration test** with Vitest + Testing Library + MSW? Write it there.
- Only write E2E when the behavior requires a real browser + real routes + real data flow — and state that justification in the spec's "Why E2E and not integration" field.

## Self-healing handoff

When new tests land, they become Phase 3 Heal candidates automatically. Every test you add should be written so selector drift (accessible name change, reorder) can be healed mechanically — that's what the locator priority rule enforces.
