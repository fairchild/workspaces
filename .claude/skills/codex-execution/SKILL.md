---
name: codex-execution
description: Dispatch codex CLI (gpt-5.6-sol xhigh) as the implementing agent for a well-specified issue — codex commits locally in a dedicated worktree, the orchestrator reviews, gates, and ships. Use when delegating implementation work to codex ("dispatch to codex", "codex implements"), especially when Claude subagent capacity is constrained. Complements codex-review-loop (codex as reviewer).
---

# Codex as Execution Agent

Codex implements; the orchestrator ships. Codex gets a dedicated worktree and a
scope-fenced brief, commits locally, and writes an untracked `CODEX_REPORT.md`.
It never pushes, opens PRs, or touches issues — review, rebase, gate re-runs,
evidence, and merge stay with the orchestrator. Proven on #901/#932
(2026-07-08): one pass, correct root causes for two e2e races, unprompted
mutation checks, ~208k tokens; the orchestrator review found one real gap.

## Dispatch

```bash
git -C <repo> fetch origin main   # ALWAYS — a stale origin/main base costs a
                                  # surprise rebase later (bit twice in W6)
git -C <repo> worktree add -b codex/<slug> <worktree-path> origin/main
codex exec --cd <worktree-path> \
  -c model='"gpt-5.6-sol"' -c model_reasoning_effort='"xhigh"' \
  --dangerously-bypass-approvals-and-sandbox \
  "$(cat brief.md)" </dev/null
```

**Foreground-synchronous, stdin closed.** A backgrounded codex hangs on
"Reading additional input from stdin…" with zero output — this stalled three
agents in one arc. Run it in the foreground of a background *shell* if you need
to keep working, but always `</dev/null`.

**Reasoning effort tiers by blast radius, not diff size.** Auth, credentials,
billing, concurrency, and process-spawning code get `xhigh` regardless of how
small the change looks; pure visual polish can run `medium`/`high`. (W6
counter-example to size-tiering: the smallest task's review found its only
blocker.)

**Quota walls are a state, not a scheduling problem.** When codex returns
"usage limit … try again at HH:MM", record the retry time and redispatch when
you're next active after it — do NOT queue the retry behind a long `sleep`; a
session restart silently kills it and the dispatch is lost (happened in W6).

## The brief

Structure per [references/brief-template.md](references/brief-template.md). The
non-negotiables:

- **Scope fence** — exact directories/files it may modify.
- **Deliverable contract** — local conventional commits only; no push, no PR,
  no issue edits; final summary to an untracked `CODEX_REPORT.md` (root cause,
  fix, repro counts before/after, gate results, mutation checks, deviations).
- **Reproduce before fixing** — for bugs/flakes, record how many runs the
  reproduction took; forbid timeout-bumping as a fix.
- **Mutation checks** — re-introduce the defect, confirm the failure returns,
  restore.
- **Verification gates** — the exact commands that must be green, run BARE:
  never piped through `tail`/`rg` (pipelines return the last command's exit
  code and greenwash failures — this shipped a red suite to a commit in W6).
- **House rules the worktree can't teach** — cleanup via `pnpm run clean`
  (never ad-hoc `rm -rf`), a full port block per worker (`E2E_PORT`,
  `EVIDENCE_PORT`, `PERF_PORT` — all three collide across parallel workers,
  and a dead harness can orphan its server on the port), no broad `pkill`.

## Orchestrator gating (after codex returns)

1. Read `CODEX_REPORT.md` + the full diff; react with attributed commits
   (`In response to my (…) review of the codex (gpt-5.6-sol, xhigh) implementation`).
   **Stage explicit paths, never `git add -A`** — a sweep in a worktree
   commits the untracked report (now also gitignored, but the habit matters).
2. Rebase onto current `origin/main`; **clean stale build state before
   re-gating** (`pnpm run clean build`) — a pre-rebase `.next` serves old
   behavior and fails/greenwashes specs. Building while a dev server runs on
   the same `.next` corrupts it the same way.
3. Run the **directed codex review** (per `codex-review-loop`) on the final
   tree — implementation plus your reactions, so reactions get reviewed too.
   The orchestrator review's chief product is the reviewer's *directed focus
   areas*, not its own verdict: in the W6 arc this second pass found disjoint
   blockers on every task (15 findings across 6 issues; ~5 blockers that green
   gates would have shipped). Independence comes from fresh context and an
   adversarial frame, not from a different model. Substantial findings go back
   to codex as a hardening brief with your decisions stated; small ones you
   fix directly.
4. Re-run every gate on the final tree (lint, typecheck, unit, e2e, any
   stability loops the brief demanded).
5. Evidence, draft PR labeled `author:codex`, readiness, merge — the normal
   mergeability flow. The PR body narrates the loop: who implemented, what
   each review pass found, mutation-check results.
