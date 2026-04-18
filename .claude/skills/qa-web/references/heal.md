# Phase 3 — Heal

Triage a failing Playwright test. Distinguish selector drift (auto-patchable) from real regressions (escalate). Delegate the mechanical patch work to Playwright's Healer subagent.

## Preconditions

- A failing Playwright test (from local run, CI, or `web/playwright-report/`).
- `web/.claude/agents/playwright-test-healer.md` exists (created by `mise run web:qa:init-agents`). Doctor check #15 enforces this.

## Procedure

1. **Pull the failure.** If the caller gave a test path, use it. Otherwise pick up the most recent failing spec from `web/playwright-report/` or the latest CI run (`gh run view --log-failed`).
2. **Capture failure evidence** under `output/qa-agent/<ISO-date>/heal-<slug>/`:
   - `failure.png` — screenshot at point of failure.
   - `trace.zip` — Playwright trace if available.
3. **Invoke the Playwright Healer subagent:**
   ```
   Agent({
     subagent_type: "playwright-test-healer",
     description: "Heal failing <test-path>",
     prompt: "The test at <test-path> is failing. Replay it against the live app, diagnose, and propose a patch. Do not commit; return the diff and a classification (selector drift vs behavior change vs structural change)."
   })
   ```
   The Healer uses `mcp__playwright-test__test_run`, `test_debug`, and `browser_generate_locator` tools to reproduce and diagnose.
4. **Classify the proposal** the Healer returns. Compare to the original test:

   | Original → Proposed | Classification | Action |
   |---|---|---|
   | Selector changed, assertion same, flow same | **Selector drift** | Accept, run, commit. |
   | Assertion changed (e.g. expected text differs) | **Behavior change** | STOP. Do not accept. Write `regression.md`. |
   | New steps added / steps removed | **Behavior change** | STOP. Write `regression.md`. |
   | Healer returned no patch, or patch doesn't pass | **Structural change** | STOP. Escalate. |

5. **On selector drift:**
   - Apply the patch.
   - Run the test: `pnpm exec playwright test <test-path>`. Must pass.
   - Update `web/tests/LEDGER.md` — bump the `last_verified` date.
6. **On behavior change:** write `output/qa-agent/<ISO-date>/heal-<slug>/regression.md`:
   - What the test expected.
   - What the app now does.
   - Is the new behavior intentional? (You don't know — that's the caller's call.)
   - Suggested next step: fix the app, update the spec, or remove the test.
7. **If two Healer attempts fail:** stop. Summarize and escalate. Paperclips are not a fix.

## Fallback: no Healer available

If the `playwright-test-healer` subagent is missing, do the diagnosis manually: `pnpm exec playwright test <test-path> --ui` for interactive debugging, inspect the trace (`pnpm exec playwright show-trace`), and propose a patch yourself. The classification rules above still apply.

## What counts as "same oracle"

The oracle is the observable outcome the test is verifying. Examples:

- Oracle A: "send button becomes enabled when user types". Locator can change (`button[aria-label=...]` vs `getByRole("button", { name: /send/i })`) and the oracle is the same.
- Oracle B: "send button shows a loading spinner while the request is in flight". If the Healer changes the assertion from a spinner to a disabled state, **that's a different oracle** — behavior change, not drift.

When in doubt, the oracle is what's in the `web/specs/<slug>.md` "Assertions" section. If the spec doesn't exist, the test IS the spec, and you must reconstruct the intended oracle before patching.

## Rationalization counters

| Temptation | Counter |
|---|---|
| "The Healer's patch changed the assertion but the new assertion also passes — ship it" | Passing ≠ correct. The new assertion tests something different. Do regression analysis. |
| "I'll just delete the failing test" | Deletion masks the issue. If the behavior was removed on purpose, the ledger + spec should be updated and the test removed explicitly, not silently. |
| "Two Healer attempts failed; let me try a third" | Stop. Two failures means the change isn't mechanical. Escalate. |
