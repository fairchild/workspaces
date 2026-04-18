# qa-web

A project-local Claude Code skill that turns `/qa` into a complete QA workflow for the `web/` Next.js app — **change-aware, evidence-producing, BLUF-summarized**, with explicit hand-offs to product-fix agents.

This file is for humans. The agent-facing procedure lives in `SKILL.md`.

## TL;DR

`/qa` on any branch produces a browser-openable report that starts with a one-sentence summary of what was found, a list of recommended actions, and a click-to-copy prompt you can paste into an agent session to request the fix. Evidence (screenshots, axe dumps, repro steps) is uploaded to R2 so you can share URLs, not paths.

Under the hood it exercises the app black-box, captures a11y findings, cross-references a behavior ledger (`web/tests/LEDGER.md`), and — when authoring new tests — delegates code generation to Playwright's official init-agents while you keep the spec-first, human-gated review.

## When to use it

- Before a PR: `/qa` — scoped to what you changed, surfaces what you might've broken
- After a PR merges but CI is red: `/qa heal <test-path>` — triage selector drift vs real regression
- When you've added a feature: `/qa author <slug>` — spec-first, human-approved test generation
- Monthly coverage audit: `/qa ledger` — summarize behaviors with stale `last_verified` dates or known gaps

## Core concepts

Each one is linked to the reference file where the detail lives.

| Concept | One-liner | Reference |
|---|---|---|
| **Four phases** | Scope → Explore → Author → Heal. `/qa` picks which run based on args. | `SKILL.md` |
| **Scope (Phase 0)** | git/gh reconnaissance that ranks user-visible surfaces by "changed ∧ uncovered." | `references/scope.md` |
| **Explore (Phase 1)** | Black-box heuristic testing (SFDIPOT + FEW HICCUPPS + axe). No reading `web/src/**`. | `references/explore.md` |
| **Author (Phase 2)** | Spec-first. Write the behavior in Markdown, get human approval, then generate the `.spec.ts`. | `references/author.md` |
| **Heal (Phase 3)** | Replay a failing test; classify as selector drift (patch) vs behavior change (escalate). | `references/heal.md` |
| **BLUF** | "Bottom Line Up Front" — every report leads with a natural-language TL;DR + recommended actions. Details collapse below. | `SKILL.md` § Output format |
| **axe** | Deque's accessibility-testing engine, run via `@axe-core/playwright`. Catches ~30–40% of real WCAG issues. | in-report glossary |
| **Oracle** | How you know behavior is correct. SFDIPOT + FEW HICCUPPS frameworks. | `references/oracles.md` |
| **Locator priority** | `getByRole` → `getByText` → `getByLabel` → `getByTestId` → CSS last. Hard rule. | `references/locator-priority.md` |
| **Trophy shape** | Integration > unit > E2E in test distribution. Refuse E2E when integration suffices. | `references/author.md` |
| **LEDGER** | `web/tests/LEDGER.md` — behavior → test → last-verified date. The coverage source of truth. | (the file itself) |
| **Evidence root** | `output/qa-agent/<ISO-date>/<slug>/` — gitignored, uploaded via `scripts/evidence.sh`. | `references/evidence.md` |

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              /qa <args>                                    │
│                          .claude/commands/qa.md                            │
│                                                                            │
│   routes based on args:                                                    │
│     • subagent path (default, isolated context) →  qa-web-agent            │
│     • inline path (run, ledger, doctor, or explicit `inline …`)            │
└──────────────────────┬─────────────────────────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────────────────────────────┐
│               .claude/agents/qa-web-agent.md (~30 lines)                   │
│                                                                            │
│  Thin wrapper. First action: Read .claude/skills/qa-web/SKILL.md and       │
│  follow it verbatim. Provides context isolation; enforces tool contract.   │
└──────────────────────┬─────────────────────────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                .claude/skills/qa-web/SKILL.md                              │
│                                                                            │
│  1. scripts/doctor.sh — 15 setup checks (fail fast)                        │
│  2. dispatch by arg:                                                       │
│       ┌───────────┐ ┌───────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────┐  │
│       │  Scope    │→│  Explore  │ │ Author  │ │  Heal   │ │ run/ledger  │  │
│       │(Phase 0)  │ │(Phase 1)  │ │(Phase 2)│ │(Phase 3)│ │             │  │
│       └─────┬─────┘ └─────┬─────┘ └────┬────┘ └────┬────┘ └──────┬──────┘  │
│             │             │            │           │             │         │
│             │             │            ▼           ▼             ▼         │
│             │             │  web/.claude/agents/playwright-test-*.md       │
│             │             │  (MCP-backed Planner / Generator / Healer)     │
│             │             │                                                │
│  3. scripts/render-report.py — aggregate to REPORT.md + report.html        │
│     + BLUF terminal output (TL;DR + actions + click-to-copy fix prompt)    │
└────────────────────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                output/qa-agent/<ISO-date>/                                 │
│                                                                            │
│     REPORT.md       ← aggregated, collapsible, markdown (GitHub/editor)    │
│     report.html     ← self-contained, dark-mode, click-to-copy prompt      │
│     <slug>/finding.md ← one per finding                                    │
│     <slug>/*.png      ← screenshots                                        │
│     <slug>/*-axe.json ← axe violation dumps                                │
│                                                                            │
│     Uploaded to R2 via scripts/evidence.sh → evidence.cloudcompute.com     │
└────────────────────────────────────────────────────────────────────────────┘
```

### Why the subagent + skill split

- The **skill** holds the procedural knowledge: phases, references, scripts. Composable — anything can invoke it inline.
- The **subagent** wraps the skill in an isolated context window. Exploration artifacts don't pollute the caller's thread; persona stays consistent; tool contract is declared once.
- The **slash command** dispatches between the two. Subagent by default (sandboxed), inline for quick operations like `/qa ledger` or `/qa doctor`.

### Why spec-first / human gate

LLM-generated tests, written from the implementation, become tautologies — they assert what the code does, not what the user expected. The human gate on `web/specs/<slug>.md` forces a behavior statement the test is anchored to. Playwright's Generator only runs after that approval.

### Why black-box during Explore

During Phase 1 the skill forbids reading `web/src/app/**` or `web/src/lib/**`. Reading the implementation makes you mirror it. A user doesn't have that option — they drive the app. The restriction is prompt-level discipline (not a hard sandbox); context isolation is the subagent's real deliverable.

## Directory layout

```
.claude/skills/qa-web/
├── SKILL.md              ← agent-facing procedure (<500 lines, the "what to do")
├── README.md             ← this file — human orientation
├── references/           ← one topic per file, loaded on demand by the agent
│   ├── setup.md          ← required project state + remediation source
│   ├── doctor.md         ← the 15-check verification recipe
│   ├── scope.md          ← Phase 0 procedure
│   ├── explore.md        ← Phase 1 procedure
│   ├── author.md         ← Phase 2 procedure (spec + Generator delegation)
│   ├── heal.md           ← Phase 3 procedure (Healer delegation)
│   ├── oracles.md        ← SFDIPOT + FEW HICCUPPS cheatsheets
│   ├── locator-priority.md ← hard rule; why Playwright role-first
│   ├── spec-template.md  ← behavior-spec Markdown template
│   └── evidence.md       ← where artifacts go; upload convention
└── scripts/
    ├── doctor.sh         ← 15-check setup verifier; exit 1 if broken
    ├── scope-report.sh   ← git + gh reconnaissance → draft Scope Report
    └── render-report.py  ← aggregates evidence dir → REPORT.md + report.html
```

## Quick start

```bash
# verify environment
/qa doctor
# OR from terminal:
bash .claude/skills/qa-web/scripts/doctor.sh

# bare run — scope the current branch, then explore scoped surfaces
/qa

# free-form change summary (used as authoritative scope)
/qa we just rewrote the auth middleware

# scoped exploration
/qa explore dashboard

# spec-first test authoring with human gate
/qa author dashboard-color-contrast

# triage a failing Playwright test
/qa heal web/e2e/full/chat.spec.ts

# fast path — no subagent, just run the existing suite
/qa run

# coverage check
/qa ledger
```

## Extending

- **Add a new reference topic** — drop a file in `references/`, link it from `SKILL.md` with a one-line description of "when to read."
- **Add a new script** — drop in `scripts/`, mark executable, reference from `SKILL.md` or a phase file. Add a doctor check if the skill depends on it.
- **Change the report look** — `render-report.py` is a single-file `uv` script; CSS and templates are inline. Re-run with `--open` to see changes.
- **Edit an invariant** — update both `SKILL.md` (human- and agent-readable rule) and the relevant phase reference. The rationalization table at the end of `SKILL.md` is where you encode the counters to agent shortcut-taking.

## Related

- `.claude/agents/qa-web-agent.md` — the subagent wrapper
- `.claude/commands/qa.md` — the slash-command dispatcher
- `web/.claude/agents/playwright-test-{planner,generator,healer}.md` — Microsoft's MCP-backed agents, generated by `mise run web:qa:init-agents`
- `web/tests/LEDGER.md` — coverage ledger (source of truth)
- `web/e2e/explore/` — Playwright project for exploratory runs (video + trace + axe fixture)
- `docs/development/evidence.md` — the repo's evidence upload convention
