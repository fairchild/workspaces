---
name: qa-web
description: Run, extend, and heal web/ app tests for this repo's Next.js dashboard. Use when the user asks to QA the web app, explore for bugs, add or heal Playwright tests, check accessibility, or measure coverage against behaviors. Triggers on "/qa", "qa", "test the web app", "explore the dashboard", "heal this test", "what's covered", "a11y check", "check the PR changes", "find regressions". Four phases — Scope (change-aware targeting), Explore (black-box heuristic testing), Author (spec-first test generation), Heal (selector-drift vs regression triage).
---

# qa-web

Project-scoped skill for QA of `web/` — a Next.js app with Vitest unit tests and Playwright E2E. Invoked by the `qa-web-agent` subagent (for sandboxed black-box exploration) or directly by the main session (for inline QA work).

## Overview

You are testing a Next.js dashboard. The app has an existing test suite (Vitest + Playwright projects `fast`/`full`/`demo`/`qa-explore`), a behavior ledger at `web/tests/LEDGER.md`, and an evidence convention at `output/qa-agent/<date>/<slug>/`.

Your four phases:

0. **Scope** — inspect what changed on this branch; produce a ranked list of user-visible surfaces to probe. Skip if on `main` with no caller summary.
1. **Explore** — black-box heuristic testing (SFDIPOT, FEW HICCUPPS, a11y) scoped to the P0/P1 surfaces from Phase 0. Every finding gets a screenshot + axe snapshot + repro steps.
2. **Author** — convert findings and uncovered behaviors into spec-first tests. Human approval gate on the spec, then delegate code generation to the `playwright-test-generator` subagent (installed by `mise run web:qa:init-agents`).
3. **Heal** — triage failing Playwright tests via the `playwright-test-healer` subagent; patch selector drift, escalate behavior changes.

## Normal flow

Follow this order every time the skill is invoked:

1. **Doctor first.** Run `scripts/doctor.sh` from the repo root. If it exits non-zero, the environment is not ready — read `references/setup.md` and apply fixes. Do not proceed to phases until doctor passes.
2. **Parse the invocation.** The caller tells you which phase(s) to run:
   - Bare invocation, or `explore` with no area → Phase 0 → Phase 1 (scoped to P0/P1). **If Phase 0 yields no P0/P1 surfaces** (e.g. infra-only branch, or no diff), run Phase 1 as a baseline smoke against the existing `web/e2e/explore/` targets — you're verifying the environment, catching any accidental breakage, and refreshing the ledger's `last_verified` dates for those behaviors.
   - `explore <area>` → Phase 1 only, scoped to `<area>`. Skip Phase 0.
   - Free-form change summary (e.g. "we just rewrote the auth middleware") → Phase 0 with summary as authoritative intent → Phase 1.
   - `author <slug-or-spec-path>` → Phase 2. See `references/author.md`.
   - `heal [test-path]` → Phase 3. See `references/heal.md`.
   - `run` → just `mise run web:check && mise run web:e2e`, structured summary, candidates for `/qa heal`.
   - `ledger` → read `web/tests/LEDGER.md`, summarize gaps (`[gap]` rows, `last_verified` > 30 days old).
3. **Execute the phase.** Follow the referenced procedure file.
4. **Render the report.** Run `.claude/skills/qa-web/scripts/render-report.py --latest` (or pass the run directory explicitly). It aggregates every `finding.md` + axe artifact in the run into:
   - `REPORT.md` — consolidated markdown, grouped by severity, with a Decisions section.
   - `report.html` — single-page browser view with inline screenshots.
   - A short terminal summary (findings counts + evidence paths + open-in-browser hint).
5. **Present and decide.** Emit the terminal summary back to the caller, point them at the HTML, and explicitly ask for a decision per finding: **promote** (Phase 2 author), **log-as-gap** (LEDGER row), **fix** (bug issue), **dismiss** (document why), or **investigate** (tighter `/qa explore`). Do not advance until the caller chooses.

## Invariants

Hard rules. Violating any of these is a bug in the run.

1. **Black-box during Explore.** In Phase 1 do NOT Read or Grep `web/src/app/**` or `web/src/lib/**`. Allowed during Explore: `web/tests/LEDGER.md`, `web/e2e/**`, `web/docs/**`, `README.md`, `AGENTS.md`, `CLAUDE.md`. Phase 0 may use `git`/`gh` metadata (file names, commit subjects, PR title/body) — that's not a violation. Reading the actual diff *content* of `web/src/**` is forbidden unless the caller explicitly authorizes it.
2. **Spec-first during Author.** Write the behavior spec under `web/specs/<slug>.md` *before* any test code. Pause for human approval. If the only source of truth for the behavior is the implementation, flag it and ask — do not write a tautological mirror test.
3. **Locator priority is non-negotiable.** `getByRole` → `getByText` → `getByLabel` → `getByTestId` → CSS last. Never raw class selectors or `nth-child` without justification. See `references/locator-priority.md`.
4. **No snapshot-only assertions.** `toMatchSnapshot()` requires at least one behavioral assertion alongside.
5. **No live-LLM calls inside Vitest.** Unit tests use deterministic mocks. For agent-runtime tests, extend `web/src/lib/agent-runtime/mock-provider.ts`.
6. **Every finding gets evidence.** Screenshot + axe snapshot + reproducible steps under `output/qa-agent/<ISO-date>/<slug>/`. Upload via `scripts/evidence.sh` when a PR is involved.
7. **Viewport matrix for Explore.** 1440×900 desktop and 375×667 mobile, minimum.
8. **Trophy shape over pyramid.** Before writing an E2E, justify why integration can't cover it. Decline E2E sprawl.
9. **Heal vs regression.** A selector-drift heal (same oracle, different selector) is safe. A behavior-change heal (new oracle, different flow) is not — stop and escalate.

## Phase details (load as needed)

| Phase | Reference | When to read |
|---|---|---|
| 0 — Scope | `references/scope.md` | Bare `/qa`, or caller provided a change summary |
| 1 — Explore | `references/explore.md` | Every invocation that probes the app |
| 2 — Author | `references/author.md` | `author <slug>` or promoting an Explore finding |
| 3 — Heal | `references/heal.md` | `heal [test-path]` or CI went red |

Supporting references (load on-demand):

- `references/setup.md` — what the project must have configured for this skill to work; source of truth for doctor fixes.
- `references/doctor.md` — the verification checklist `scripts/doctor.sh` enforces.
- `references/locator-priority.md` — Playwright locator rule, why it matters.
- `references/spec-template.md` — the behavior-spec Markdown template for Phase 2.
- `references/oracles.md` — SFDIPOT + FEW HICCUPPS heuristics for exploration.
- `references/evidence.md` — evidence layout and upload conventions.

## Scripts

- `scripts/doctor.sh` — verify setup; exit 0 if ready, non-zero if not (prints remediation hints).
- `scripts/scope-report.sh` — git + gh reconnaissance; prints the Phase 0 Scope Report.
- `scripts/render-report.py` — aggregate a run's findings into `REPORT.md` + `report.html` with screenshots inline. Pass `--latest` to pick the most recent date dir under `output/qa-agent/`. Pass `--open` to open the HTML in the default browser.
- `web/scripts/qa-probe.mjs` *(lives in the project, not the skill)* — axe-core + screenshots on a list of URLs. Invoke with `QA_SLUG=<slug> QA_BASE_URL=<url> node web/scripts/qa-probe.mjs`.

Relevant mise tasks (in `web/.mise.toml`):

- `web:e2e:explore` — run the qa-explore Playwright project.
- `web:qa:init-agents` — one-shot: scaffold Playwright's agent-loop instruction files (optional, complementary).
- `web:qa:codegen [url]` — record interactions into a starter `.spec.ts`.

## Output format

End every run with this block:

```
## qa-web report — <phase(s) run> — <ISO date>

**Branch / PR:** <branch> / #<pr or "none">
**Scope:** <caller summary, or "bare /qa — derived from diff">

**Findings:**
- [P0] <issue> — <path to evidence>
- [P1] <issue> — <path to evidence>
- [gap] <uncovered behavior> — proposed spec: <path>

**Next steps:**
- <concrete action for the human>

**Ledger updates:** <n> rows added / updated in web/tests/LEDGER.md

**Evidence root:** output/qa-agent/<ISO-date>/
```

Do NOT open PRs yourself. Summarize the diff and evidence paths so the caller can review and open the PR.

## Rationalization table

If you catch yourself reasoning this way, stop and reread the rule.

| Temptation | Counter |
|---|---|
| "I'll just peek at `chat-panel.tsx` to understand what to test" during Explore | That's implementation-mirroring. Explore tests user-visible behavior. Close the file, drive the app instead. |
| "Snapshot is easier than writing assertions" | Snapshots without semantic assertions rot silently. Pair at least one `expect(role).toBeVisible()`-equivalent with any snapshot. |
| "This test is flaky, I'll add `waitForTimeout(5000)`" | Flakiness is a signal about the selector or the oracle, not about timing. Replace with `expect(locator).toBeVisible({ timeout })` or `page.waitForRequest(...)`. |
| "The caller gave a summary but the diff says something else — I'll trust the diff" | The caller knows intent; the diff doesn't. Treat the summary as authoritative; note the discrepancy in the Scope Report. |
| "Healer proposed changing the assertion — close enough, ship it" | That's a behavior change, not a heal. Stop. Write a regression note. Escalate. |
| "I can skip doctor, it passed last week" | Run doctor. The environment drifts. One wasted minute beats thirty minutes debugging a missing dep. |
