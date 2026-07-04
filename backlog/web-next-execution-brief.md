# web-next Execution Brief — operating contract for the milestone orchestrator

This is the standing contract for the autonomous run that builds the
sessions-first web experience (`web-next/`). The **what** lives in the PRD
(`backlog/web-experience-redesign_plan.md`) and the per-issue acceptance
criteria; this file is the **how**: the quality bar, the loop, and the
authority under which you operate. Read it fully before picking the first issue,
and re-read the Definition of Done before every merge.

## Mission

Deliver the milestone **"Sessions-first web (web-next)"** to completion: a
browser coding-session experience where the user signs in, opens or starts a
session on a connected repo, chats with an agent that edits and runs code in a
real cloud sandbox — rendered in the Folio design system — with a transcript
that survives disconnect, a terminal into the same sandbox, deployed as the
primary web session surface. The visual system is decided: the "Refined Folio"
prototype (`prototypes/web-session-redesign/refine-folio.html`) is the spec.

## Authority

You have a **full autonomous mandate**. You make the quality decisions and the
merge decisions. Michael is not in the per-PR loop.

- **Self-merge** any PR that is scoped to `web-next/` (plus its own CI/docs) and
  meets the Definition of Done below. Green + evidenced + within perf budget is
  pre-approval.
- **Escalate to Michael** (open the PR, do not merge, and leave a clear question)
  only when a change reaches outside `web-next/` in a risky way, incurs
  meaningful recurring cost, makes a one-way architectural decision the PRD
  didn't anticipate, has a security dimension, or when CI fails the same way
  three times and you cannot diagnose it. Taste calls are yours — do not stall a
  slice on a subjective fork you can reason about; decide, note why, move on.
- Uphold an **uncompromising bar**. "Tests pass" is the floor, not the target.
  A PR that is green but unclear, unmeasured, or ugly does not meet the bar.

## Operating mode: serial

Work **one issue at a time, in issue order**. Concurrency is explicitly not
wanted here — a clean, legible, well-verified relay beats a fast fan-out. You may
still spawn subagents *within* an issue (a reviewer, a verifier, a perf runner),
and route by strength: Fable for the Folio/UI component work, a stronger model
(Opus) for the hairy backend (schema, durable/resumable turns, provider
lifecycle, terminal port). But land one issue, merge it, reassess, then take the
next.

## Definition of Done — every PR must clear all of these

1. **Acceptance criteria met** — each checkbox in the issue, verified against the
   actual tree (not assumed). Close the issue with `Closes #N`.
2. **Green CI** — the `web-next` lane (lint, typecheck, unit, build, Playwright,
   perf) passes. No skips, no `[pending-ci]`.
3. **Evidence, including screenshots** — most PRs change UI; those MUST include a
   screenshot (or short video for motion) of the actual surface, captured from
   the commit under review, in **both light and dark**. Backend-only PRs attach
   test output and, where behavior is observable, a captured trace. Paste hosted
   links (or a green-CI artifact link) into the PR body — never local-only paths.
4. **Self-verification** — you drove the real flow, not just the tests. For a UI
   slice that means loading the surface and exercising it (send a message, watch
   it stream, toggle theme); for a backend slice, exercising the endpoint/turn
   end to end. Use the `verify` skill's discipline: observe behavior, don't infer
   it from a passing suite.
5. **Performance measured** — for any perf-sensitive change (streaming,
   transcript render, routing, providers, tail/resume) run the perf harness and
   paste before/after/delta against the canonical scenarios. A metric regressing
   past its budget blocks the merge until fixed or explicitly re-budgeted with a
   reason.
6. **Readability & maintainability — non-negotiable** — run `/code-review` and
   `/simplify` and act on them. Names say what they mean; types carry the intent;
   files that aren't self-evident open with a short purpose block; no dead code,
   no commented-out code, no copy-paste that should be a function. A reviewer
   opening this cold should understand it without you in the room.
7. **Tests** — behavior over implementation. New behavior worth keeping gets a
   test; the `web-next` test suite grows with the surface.

## Performance discipline

Stand up the perf harness in the first issue (T0) and keep a
`web-next/perf/contract.json` of canonical scenarios + budgets (mirrors the
Swift app's `config/performance/contract.json` culture). Track, at minimum:

- **Time-to-first-token** — send → first token painted (separate budgets for the
  mock provider and a real sandbox, since provisioning dominates the latter).
- **Streaming cadence** — no long task >50ms while tokens arrive; the transcript
  stays at 60fps. Token application is batched (rAF), not per-chunk React state.
- **Transcript render at scale** — seed ~200 messages; initial render and scroll
  stay within budget (reach for virtualization only if measurement demands it).
- **Route performance** — `/` and `/sessions/[id]`: LCP, TBT, and first-load JS
  budget.
- **Resume latency** — reconnect → caught up for a ~100-event log.

Establish the baseline early; from then on **no PR regresses a tracked metric
past budget** without an explicit, reasoned re-budget. The point is a quantified,
defended "fast" — not a vibe.

## Reassessment loop — after every merged PR

The tracker lags the code; treat the plan as living.

1. Re-read the milestone and the remaining issues.
2. `rg` each remaining issue's acceptance criteria against the current tree —
   close anything already satisfied, in the same cycle.
3. If reality diverged from the plan (a slice was bigger/smaller than thought, an
   ordering is now wrong, a new prerequisite appeared), **edit the issues and the
   PRD** to match before continuing. Split, merge, reorder, or add issues as the
   work teaches you. Note what you changed and why in the issue.
4. Then pick the next issue.

## Scope guards

- **Single-user.** No multi-tenant authorization matrix, no onboarding polish, no
  data migration. Auth is OAuth + a login allowlist.
- **Harness runtime, behind our own interface.** The session runtime is
  `@ai-sdk/harness` (Claude Code / Codex / Pi), wrapped by a thin app-owned
  `SessionRuntime` interface so the experimental API never leaks app-wide — see
  `docs/decisions/web-next-harness-runtime.md`. The harness owns stream→UIMessage
  projection, sandbox + CLI auth, and multi-runtime dispatch; we own persistence,
  reconnect policy, and the terminal. **Exact-pin** every `@ai-sdk/harness*` and
  `@ai-sdk/sandbox-*` version; upgrade deliberately. Spike it (T0.5) before
  building UI on it. Because a real runtime is now as easy as a mock, stream a
  **real** provider from the first slice — do not build a long mock phase.
- **Reconnect (v1).** Between-turn durability + server-side long-turn continuation
  are in scope; **mid-turn live tail is deferred** — a turn keeps running
  server-side and we re-attach or replay the completed transcript on reconnect.
- **Don't disturb the old app.** `web/` keeps serving webhooks and the managed PR
  reviewer until the final cutover issue; nothing before it touches that path.

## Authoritative ticket order

This list supersedes any ordering elsewhere. Serial; one at a time.

1. **#744 · T0** — CI + evidence + performance harness.
2. **T0.5 (new)** — Harness runtime spike: real Claude Code turn via
   `@ai-sdk/harness` + `@ai-sdk/sandbox-vercel` → `toUIMessageStream` → `useChat`,
   auth working in-sandbox, exact-pinned, behind the `SessionRuntime` interface.
   De-risks the experimental dependency before any UI is built on it.
3. **#745 · T1** — Folio design system as React components.
4. **#746 · T2** — Chat persistence: stored UIMessages + `resumeFrom` blob per
   session (harness owns the projection; we own the store + read-back).
5. **#747 · T3** — Auth + sessions home + new-session flow, incl. a **runtime
   picker** (Claude Code / Codex / Pi).
6. **#748 · T4** — A **real Claude Code** turn streams into the live Folio
   transcript (not mock).
7. **#749 · T5** — Durability: between-turn resume + long-turn slicing via the
   harness workflow utilities; v1 reconnect = re-attach/replay.
8. **#750 · T6** — Multi-runtime: add the **Codex** and **Pi** adapters behind the
   interface + picker.
9. **#752 · T8** — Terminal drawer: ttyd on a sandbox port (shared-sandbox
   pattern) + ghostty-web.
10. **#753 · T9** — Lifecycle controls + error states + mobile.
11. **#754 · T10** — Cutover.

**#751 · T7 (Managed Agents) is closed** — not a harness, out of web-next scope.

## Quality-gate review

Because the runtime rides an experimental API, the quality gate is not
self-attestation alone: for every PR touching the runtime/backend seam (the spike,
persistence, durability, multi-runtime, terminal), run the `/code-review` pass via
a **separate reviewer subagent on a stronger model (Opus)** before merging, and
treat any harness API surprise (a rename, a missing capability, a behavior that
contradicts the docs) as an escalation-worthy architectural signal, not a
work-around to bury.

## Tooling

Use the repo's machinery: the `drive` skill for milestone delivery, the
`subagent-delegation` skill for within-issue fan-out, `verify` for
self-validation, `/code-review` and `/simplify` for the quality gate, `qa-web`
for the Playwright/evidence lane, and `evidence.sh` (or the sanctioned remote
fallbacks in `docs/development/remote-sessions.md`) for hosted evidence.

## Stop condition

The milestone is done when every issue's acceptance criteria are met, `web-next`
is the primary session surface at its URL, the old chat/terminal tabs are
demoted, and the docs/LEDGER reconcile. At that point, report to Michael with the
final state and the evidence trail.
