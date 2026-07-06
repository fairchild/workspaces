# web-next — Roadmap

The path from *first release* to **totally usable**: a single person can sign in
to the deployed app, start a session on one of their real repos, run a real
coding turn that edits code in a sandbox, watch it stream (accessibly), resume
it across disconnects, trust it, and get the change out — every day, without
babysitting.

This is the sequencing doc. The settled *design* is [`design.md`](design.md);
the *runtime* decision is `docs/decisions/web-next-harness-runtime.md`; the data
foundation is [`schema.md`](schema.md); the environment matrix is
[`deploy.md`](deploy.md). This file is grounded in the current tree and the live
GitHub milestones, not aspiration — keep it in sync as milestones close.

## Definition of "totally usable"

The bar this roadmap is held to. A signed-in, allowlisted user, on the deployed
app, can:

1. **Sign in** with GitHub (real OAuth + allowlist) — *exists in code; not yet proven on a real deployment.*
2. **Start a session on a real repo** — pick from their actual GitHub repos, validated, default branch known. *Gap: freetext today (#825).*
3. **Run a real coding turn** — choose a model, watch it stream, it edits code in a sandbox and runs tests, and completes. *Blocked on the real runtime (#750) + model selection (#824).*
4. **Identify and resume** the session — it has a title, survives disconnect/reload, and stays correct across serverless instances. *Gaps: titling (#823), the resume-liveness bug (#810), turn concurrency (#811).*
5. **Read it well** — the transcript is accessible (screen-reader, contrast, keyboard, mobile) and **failures are visible**, not silent. *#804–#809, #808, #753.*
6. **Drop into a terminal** in the session's sandbox. *#752.*
7. **Get the change out as a PR.** *#820 — needs a design pass first.*
8. **Trust all of the above** via automated validation against the real deployment. *#13.*
9. It is **the primary surface**, old chat/terminal demoted. *#754.*

## Current state (2026-07-06)

**Solid and green.** The architecture is deliberate and the gates pass — 117/117
unit tests, lint, typecheck, and a clean production build. What's built:

- The **Folio** design system (calm, typography-first) rendered from real data:
  masthead, turn-framed transcript, tool ledger, contextual diff/test panels,
  reasoning aside, end-of-turn receipt, light/dark, reduced-motion.
- **Durable turns**: an append-only `session_events` log is the source of truth;
  the transcript is *projected* at read time; a turn runs **detached** so it
  completes whether or not a browser stays connected, and a reconnect tails the
  same log. Proven by e2e (mid-stream reload + tab-close both resume).
- **Auth**: GitHub OAuth + `ALLOWED_LOGINS` allowlist, double-locked test bypass
  for e2e/evidence/perf, edge freshness + server-side allowlist verdict.
- A **mock provider** that scripts a full coding turn, and an auth-gated
  **`/api/diag/gateway`** probe that makes one real model call.

**What isn't real yet.** Everything runs the **mock**; validation is **local
only** (auth-bypass, `localhost:3100`); the app **isn't deployed** with real auth
(deploy.md: "deployment is a later issue"); and three start-loop essentials —
**titles, model selection, a real repo picker** — are missing.

## The milestones

| Milestone | What it delivers |
|---|---|
| [#11 Sessions-first web](https://github.com/fairchild/workspaces/milestone/11) | The build-out: **#750** real runtime, **#752** terminal drawer, **#753** lifecycle + error states + mobile, **#754** cutover, **#790** edit→diff, **#780** build/404 flake. |
| [#12 Refinement pass 1](https://github.com/fairchild/workspaces/milestone/12) | a11y, resilience & polish: **#804–#809** a11y/UX, **#810** resume liveness, **#811** turn concurrency, **#812** font-doc drift. |
| [#13 Self-validation](https://github.com/fairchild/workspaces/milestone/13) | Environment-targetable validation harness: **#813–#819** (local → preview → staging → prod). |
| [#14 Usability completeness](https://github.com/fairchild/workspaces/milestone/14) | The start-and-identify loop: **#823** titles, **#824** model selection, **#825** real repo picker. |
| _followup_ | **#820** agent opens a GitHub PR from a session (needs a design pass before it's `ready`). |

## Phased sequence

Ordered by the critical path to usability, not by milestone number. Phases
overlap where they don't depend on each other.

### Phase 0 — Make the foundation trustworthy *(do first / alongside Phase 1)*
The durable-turn layer has latent correctness bugs that will **corrupt real
sessions** the moment #750 puts real turns through it. Fix before scale.
- **#810** durable resume — DB-authoritative liveness across instances *(HIGH; the headline resume feature is broken on serverless today)*
- **#811** turn-runtime robustness — concurrency guard, atomic abandon-close, structured provider errors
- **#780** `next build` /404 prerender flake — de-flake the build gate

### Phase 1 — Real runtime + session identity *(the core value)*
Turn the mock into a real agent, and make a session a usable object.
- **#750** real runtime — harness-backed ComputeProvider (Claude Code in a sandbox) — **the keystone**
- **#824** per-session model selection (pick, persist, route, display)
- **#823** session titles (auto from first turn + editable)
- **#825** real GitHub-backed repo picker (validate + default branch)

### Phase 2 — Trust it: self-validation *(alongside/after Phase 1)*
Validate the *real* runtime against *real* environments — the stated priority.
Stage #818 needs #750 landed to have a real turn to exercise.
- **#813** harness core → **#814** deployed-env auth → **#815** security posture → **#816** model/gateway diag → **#817** portable browser flows → **#818** real agentic turn (sandbox lifecycle) → **#819** reporting + scheduled preview/prod runs

### Phase 3 — The transcript reads and fails well
- **#808** surface streaming turn failures (error + retry) — *pull forward; cheap, high-value*
- **#753** lifecycle controls + error states + mobile
- **#790** one representation for viewing edits (expand Edit → its diff)
- **#752** terminal drawer (PTY into the sandbox)

### Phase 4 — Accessibility & polish
- **#806** WCAG-AA contrast — *pull forward; one palette change, affects every screen*
- **#804** live-region announcements + follow-scroll, **#805** keyboard-reachable reveals + semantic heading, **#807** multiline compose, **#809** mobile touch targets, **#812** font-doc reconciliation

### Phase 5 — Ship as primary + close the loop
- **Deploy for real** — production build behind real GitHub OAuth + allowlist + Vercel protection, proven by Phase 2's validation
- **#754** cutover to the primary session surface (demote old chat/terminal)
- **#820** agent opens a PR from a session — *after its design pass*

## Critical path

```
#810/#811 (trust)  ─┐
                    ├─►  #750 (real runtime)  ─►  #818 (validate real turn)  ─►  deploy  ─►  #754 (cutover)
#824 model  ────────┘                          ▲
#823 title, #825 repo picker  ─────────────────┘   (identity/start loop)
```

Everything else (a11y, mobile, terminal drawer, edit→diff, #820) enriches the
experience but does not gate the core "sign in → real coding turn → resume →
trust → primary surface" loop.

## Pull-forward candidates

High value, low cost, no hard dependency — worth doing opportunistically ahead of
their phase: **#806** (contrast), **#808** (visible failures), **#812** (docs).

## Open design work (before implementation)

- **#820** — which credential opens the PR, branch/commit strategy, how the PR
  reads in the session UI, guardrails (draft-by-default, allowed repos/branches).
  Write a decision doc before cutting implementation issues.
- **#814** — the validation identity + Vercel protection-bypass approach
  (least-privilege, revocable). A privileged-credential decision.

## Provenance

Distilled from the first-release review (2026-07-06): three parallel lenses
(runtime correctness, design-fidelity + accessibility, build health), which
produced milestones #12–#14 and the gap issues referenced here.
