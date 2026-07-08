---
name: codex-execution
description: Dispatch codex CLI (gpt-5.5 xhigh) as the implementing agent for a well-specified issue — codex commits locally in a dedicated worktree, the orchestrator reviews, gates, and ships. Use when delegating implementation work to codex ("dispatch to codex", "codex implements"), especially when Claude subagent capacity is constrained. Complements codex-review-loop (codex as reviewer).
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
git -C <repo> worktree add -b codex/<slug> <worktree-path> origin/main
codex exec --cd <worktree-path> \
  -c model='"gpt-5.5"' -c model_reasoning_effort='"xhigh"' \
  --dangerously-bypass-approvals-and-sandbox \
  "$(cat brief.md)" </dev/null
```

**Foreground-synchronous, stdin closed.** A backgrounded codex hangs on
"Reading additional input from stdin…" with zero output — this stalled three
agents in one arc. Run it in the foreground of a background *shell* if you need
to keep working, but always `</dev/null`.

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
- **Verification gates** — the exact commands that must be green.
- **House rules the worktree can't teach** — cleanup via `pnpm run clean`
  (never ad-hoc `rm -rf`), port isolation (`E2E_PORT=<unique>`), no broad
  `pkill`.

## Orchestrator gating (after codex returns)

1. Read `CODEX_REPORT.md` + the full diff; react with attributed commits
   (`In response to my (…) review of the codex (gpt-5.5, xhigh) implementation`).
2. Rebase onto current `origin/main`; **clean stale build state before
   re-gating** (`pnpm run clean build`) — a pre-rebase `.next` serves old
   behavior and fails/greenwashes specs.
3. Re-run every gate on the rebased tree (lint, typecheck, unit, e2e, any
   stability loops the brief demanded).
4. Evidence, draft PR labeled `author:codex`, readiness, merge — the normal
   mergeability flow. Skip a second codex review pass (self-review by the
   implementer is low-signal); the orchestrator review substitutes.
