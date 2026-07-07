# web-next — Roadmap

The path from *first release* to **totally usable**: the owner signs in to the
deployed app most days, starts sessions on their real repos, runs real coding
turns that edit code in a sandbox, watches them stream (accessibly), resumes
across disconnects, trusts it — and can hand the URL to another person to try
without exposing their own sessions.

This is the sequencing doc. The settled *design* is [`design.md`](design.md);
the *runtime* decision is `docs/decisions/web-next-harness-runtime.md`; the data
foundation is [`schema.md`](schema.md); the environment matrix is
[`deploy.md`](deploy.md). This file is grounded in the current tree and the live
GitHub milestones, not aspiration — keep it in sync as milestones close.

## Definition of "totally usable"

The bar this roadmap is held to. A signed-in, allowlisted user, on the deployed
app, can:

1. **Sign in** with GitHub (real OAuth + allowlist) — *live: production serves real OAuth, the test bypass is inert, unauthed API leaks nothing (verified 2026-07-06 against web-next-ivory-six.vercel.app).*
2. **Start a session on a real repo** — pick from their actual GitHub repos, validated, default branch known. *Gap: freetext today (#825).*
3. **Run a real coding turn** — watch it stream, it edits code in a sandbox, and follow-up turns continue the same conversation and working copy. *Landed (#822 + #831, opt-in `WEB_NEXT_COMPUTE_PROVIDER=vercel`); model **selection** (#824) still open.*
4. **Identify and resume** the session — it has a title, survives disconnect/reload, and stays correct across serverless instances. *Gaps: titling (#823), the resume-liveness bug (#810), turn concurrency (#811).*
5. **Read it well** — the transcript is accessible (screen-reader, contrast, keyboard, mobile) and **failures are visible**, not silent. *#804–#809, #808, #753.*
6. **Drop into a terminal** in the session's sandbox. *#752.*
7. **Get the change out as a PR.** *Mechanics proven (#822's smoke opened #821); #820 is now the product surface design.*
8. **Trust all of the above** via automated validation against the real deployment. *#13.*
9. **Hand it to someone else to try** — sessions are owner-scoped, so an added
   allowlist login sees only their own sessions. *Deferred (2026-07-07): web-next
   is a single-user tool for now; #829 is parked (`idea`) until a real second
   login is wanted. Bars 1–8 + 10 are the live target; this bar returns when
   sharing is actually on the table.*
10. It is **the primary surface**, old chat/terminal demoted. *#754.*

> **Posture (2026-07-07 grooming).** web-next is the **web lane** of a two-lane
> product — it runs in parallel with the desktop app, one active milestone per
> lane (see `backlog/ROADMAP.md` § Milestone Alignment). It is a **single-user
> (owner) tool** until a second allowlist login is wanted: sharing (#829) and
> assistive-tech/mobile a11y (#804/#809) are deferred, while contrast/keyboard/
> visible-failure work (#805/#806/#808) stays because it serves the owner.
> **Perf floor — shipped; #856 re-scoped ([#856](https://github.com/fairchild/workspaces/issues/856)):**
> the perf floor already exists — [#761](https://github.com/fairchild/workspaces/issues/761)
> landed `web-next/perf/` (8-scenario contract + `run.mjs` + dated `BASELINE.md`)
> with `pnpm run perf` as a hard CI gate. #856 now covers two gaps: **(A)** a
> baseline-relative regression guard before the #754 cutover, and **(B)**
> deployed-target measurement (rides #814). The old "no perf budget" line was
> stale (verified 2026-07-07).

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

**Deployed and hardened at the door** *(verified 2026-07-06)*: production
(`web-next-ivory-six.vercel.app`) is live behind real GitHub OAuth + allowlist,
the Vercel SSO wall is off (anonymous reachability checks work with zero
credentials), the test bypass is provably inert, and every PR gets a Vercel
preview deployment. Two warts found at the door: unauthed API calls get a 307
HTML redirect instead of route-level 401 JSON (#828), and sessions have no
owner scoping — any allowlisted login sees all sessions (#829).

**The real runtime is live (opt-in)** *(#822 + #831, merged 2026-07-06/07)*: a
real `vercel` ComputeProvider boots Claude Code in a sandbox
(`WEB_NEXT_COMPUTE_PROVIDER=vercel`), **driven by the user's actual message**
against a persistent per-session clone, with durable cross-turn/tab-close
resume (`sessions.resume_state`), preflight diag (`/api/diag/preflight`),
out-of-band template prewarm, and the `ws` externalization that un-broke the
in-app path. #750 and #826 are closed. The mock remains the default provider.

**What isn't real yet.** Validation of the *real* path (#818 is now exercisable
— needs runtime creds where it runs); the three start-loop essentials —
**titles, model selection, a real repo picker** — and owner-scoped sessions
(#829) for shareability.

## The milestones

| Milestone | What it delivers |
|---|---|
| [#11 Sessions-first web](https://github.com/fairchild/workspaces/milestone/11) | The build-out: ~~#750/#826~~ real runtime (**landed**: #822 + #831), **#752** terminal drawer, **#753** lifecycle + error states + mobile, **#754** cutover, **#790** edit→diff, **#780** build/404 flake. |
| [#12 Refinement pass 1](https://github.com/fairchild/workspaces/milestone/12) | a11y, resilience & polish: **#804–#809** a11y/UX, **#810** resume liveness, **#811** turn concurrency, **#812** font-doc drift, **#828** API 401 JSON. |
| [#13 Self-validation](https://github.com/fairchild/workspaces/milestone/13) | Environment-targetable validation harness: **#813–#819** (local → preview → staging → prod). |
| [#14 Usability completeness](https://github.com/fairchild/workspaces/milestone/14) | The start-and-identify loop: **#823** titles, **#824** model selection, **#825** real repo picker. *(**#829** owner-scoped sessions parked `idea` 2026-07-07 — single-user tool; returns when sharing is wanted.)* |
| _followup_ | **#820** agent opens a GitHub PR from a session — mechanics proven by #821; the open design is the product surface. |

## Phased sequence

Ordered by the critical path to usability, not by milestone number. Phases
overlap where they don't depend on each other.

### Phase 0 — Make the foundation trustworthy *(do first / alongside Phase 1)*
The durable-turn layer has latent correctness bugs that will **corrupt real
sessions** the moment #750 puts real turns through it. Fix before scale.
- ~~#810~~ durable resume — **landed** (PR #830)
- **#811** turn-runtime robustness — concurrency guard, atomic abandon-close, structured provider errors *(in review, PR #832)*
- **#780** `next build` /404 prerender flake — de-flake the build gate

### Phase 1 — Real runtime + session identity *(the core value)*
Turn the mock into a real agent, and make a session a usable object.
- ~~#750/#826 real runtime~~ — **landed** (#822 plumbing + #831 message-driven turns & durable resume)
- **#824** per-session model selection (pick, persist, route, display)
- **#823** session titles (auto from first turn + editable)
- **#825** real GitHub-backed repo picker (validate + default branch)

### Phase 2 — Trust it: self-validation *(alongside/after Phase 1)*
Validate the *real* runtime against *real* environments — the stated priority.
With the SSO wall off, **#813 + #815 run against production today with zero
credentials**; #814 (a signed-in validation identity) gates the authenticated
stages; with #831 merged, #818 has a real user-driven turn to exercise — and
`/api/diag/preflight` is exactly the seam #816/#818 consume.
- **#813** harness core → **#815** security posture *(unblocked now)* → **#814** deployed-env auth → **#816** model/gateway diag → **#817** portable browser flows → **#818** real agentic turn (sandbox lifecycle) → **#819** reporting + scheduled preview/prod runs

### Phase 3 — The transcript reads and fails well
- **#808** surface streaming turn failures (error + retry) — *pull forward; cheap, high-value*
- **#753** lifecycle controls + error states + mobile
- **#790** one representation for viewing edits (expand Edit → its diff)
- **#752** terminal drawer (PTY into the sandbox)

### Phase 4 — Accessibility & polish *(thinned for single-user, 2026-07-07)*
Keep what serves the owner; defer what only pays off with an audience.
- **#806** WCAG-AA contrast — *pull forward; one palette change, affects every screen*
- **#805** keyboard-reachable reveals + semantic heading, **#807** multiline compose, **#812** font-doc reconciliation
- **Deferred pending a real audience:** **#804** live-region announcements + follow-scroll (assistive tech), **#809** mobile touch targets. Reinstate when a second person actually uses web-next.

### Phase 5 — Ship as primary + shareable
Production already exists (real OAuth + allowlist, verified); what remains is
making it *primary*, and keeping it proven. Shareability is deferred with #829.
- **#828** API routes answer 401 JSON, not a sign-in redirect
- **#754** cutover to the primary session surface (demote old chat/terminal) —
  the perf floor (#761) already gates PRs; add the baseline-relative regression
  guard (#856 Gap A) before cutover
- **#820** agent opens a PR from a session — *after its design pass*
- **#829** per-user session ownership — *parked `idea`; the prerequisite to
  adding anyone else to the allowlist. Reinstate this phase when sharing is on
  the table.*

## Critical path

```
#810/#811 (trust)  ─┐
                    ├─►  ✅ real turns (#822+#831)  ─►  #818 (validate real turn)  ─►  #754 (cutover)
#824 model  ────────┘                          ▲
#823 title, #825 repo picker  ─────────────────┘   (identity/start loop)

#829 (owner-scoped sessions)  ─►  add a second allowlist login  ─►  shareable
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
