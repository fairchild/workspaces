---
status: design-record
date: 2026-07-12
current-state: docs/development/factory-current-state.md
supersedes: docs/development/agent-team.md (architecture; file to be rewritten in M1)
related:
  - docs/agents/GLOSSARY.md
  - docs/decisions/factory-label-control-plane.md
  - docs/decisions/factory-event-driven-stages.md
  - docs/decisions/factory-persona-memory.md
---

# Agent Factory v2

> **Design record.** This document captures the decisions, rationale, and milestone roadmap behind the Factory pipeline as of 2026-07-12. For what's actually live today — which lanes run, their trigger/guard/status, the `FACTORY_*` switch inventory, how to enable or disable a lane, the `factory/ops-data` branch contract, and dashboard usage — see [`docs/development/factory-current-state.md`](./factory-current-state.md).

The Factory is the autonomous development system that advances this repo between the Owner's interactive sessions. This plan replaces the v1 "Agent Team" architecture (scheduled persona wake-ups coordinating through GitHub Discussions) with an event-driven, label-fired pipeline. Language is canonical in [docs/agents/GLOSSARY.md](../agents/GLOSSARY.md); decisions were made in a grilled design session on 2026-07-12 against a live-state audit, an infrastructure deep-dive, and Warp's published software-factory work.

## Purpose

Twofold, in priority order:

1. **Learning lab.** Push the state of the art in agent-run development; the telemetry, persona divergence, and dial-turning history are deliverables in their own right, carried into the Owner's other work.
2. **Steady metabolism.** Advance the product through the weekday lulls between the Owner's spiky engagement, growing toward a self-sustaining — eventually perhaps commercial — product.

v2's role is **background metabolism with a growth path to a second engine**. The Factory does not originate feature ideas in v2; origination earns its way back through the autonomy gradient. Work enters through Inlets that carry real demand: product feedback, Owner Steering, and the Factory's own operational signals (CI failures, monitor findings).

## Why v1 stalled (audit, 2026-07-12)

v1 failed at **conversion, not execution**:

- Execution was fast and reliable: 141 agent-lane PRs merged in 60 days at an 18-minute median; agent workflow success >85%.
- Every conversion gate fanned into the Owner on a surface he stopped visiting. Idea→plan required an exact keyword comment (Peter's last successful run: April 11; its one genuine "plan it" trigger failed silently). Plan→execute required a 👍 on a specific comment. Discussions went fully silent June 9; 22 of 25 open discussions sat idle >14 days; zero `[idea]` discussions converted in 60 days.
- The contributor runtime was structurally biased against finishing: one action per wake-up, review-always-wins priority, propose-new-idea as the terminal fallback, `recommend_close` unreachable dead code, no cross-run memory, claims expiring silently. April authored 2 PRs ever; Plat 0 — against 106 reviews between them.
- Observability was broken by construction: Oliver computed a weekly ops report and discarded it (read-only token, no commit step). `docs/ops/` froze on 2026-03-12.

Model capability was at most secondary: agents did what the pipeline permitted. The architecture made proposing cheap and finishing impossible. Better models in the same pipeline would have stalled identically.

## Decisions

| # | Decision |
|---|---|
| D1 | **Role**: background metabolism, growth path to second engine; no agent-originated feature ideas in v2 |
| D2 | **Control plane**: issue labels + PR state only; a Gate is exactly a label flip, a PR review, or a merge; comment keywords and reactions are never control signals |
| D3 | **Interface**: one pinned Digest discussion + committed dashboard; PR-shaped gates; the product's feedback box is the Owner's Steering inlet; WorkSpaces-app Attention integration later |
| D4 | **Pipeline**: six event-fired Stages; the Monitor's daily pulse is the only heartbeat; an idle Factory does nothing |
| D5 | **Personas**: rebound to roles — April/Plat as implement/review pair (counterpart always reviews), Peter as triage + spec author, Oliver as the deterministic Monitor's name; no Persona is ever scheduled to find work |
| D6 | **Memory**: per-Persona Memory Blocks + Profile, self-managed, peer-reviewed via PRs; append-only Journal as the only direct-write surface; Dreaming later |
| D7 | **Feedback inlet**: poll cron → triage; Owner Steering flows gateless; non-owner publication is Owner-gated in v1, widened later |
| D8 | **Autonomy gradient**: explicit gate map, measured instruments, pre-defined auto-merge class (disabled); Owner intends to delegate merges as reviewer-agreement evidence accumulates; privileged paths stay Owner-merged forever |
| D9 | **Safety**: v1 posture carries over plus five deltas (memory carve-out, per-stage + global kill switches, spend caps, label-only triage powers, ruleset note) |
| D10 | **Cleanup**: close all 25 discussions; batch re-triage the 52 agent issues via one disposition table; retire v1 machinery in one PR wave; fossil ideas are not auto-converted |
| D11 | **Rollout**: M0–M6 below; the Factory never builds itself autonomously — its own code ships only through Owner-merged PRs |

## The pipeline

| Stage | Persona | Trigger | Does | Builds on |
|---|---|---|---|---|
| Triage | Peter | issue opened; feedback poll cron | understand/reproduce; route small+clear → `ready`, large/ambiguous → `spec`, unclear → comment + leave in `needs-triage` (no dedicated label since the `needs-info` label was removed 2026-08-02), someday → `idea`; sanitize + dedup feedback | new |
| Spec | Peter | `spec` applied | write `specs/<slug>/PRODUCT.md` + `TECH.md`; open spec-only PR | new; Warp's spec-skill shape |
| Implement | April or Plat | `ready` applied | claim → branch → implement → evidence → PR (`Closes #N`) | evidence lane (`_evidence.yml`, `evidence.sh`) reused as-is |
| Review | the counterpart | agent PR opened | review against mergeability standard; apply `mergeable` | the one organically working v1 behavior |
| Verify | — | PR gate | tests, screenshots, smoke lanes | exists; ahead of reference designs |
| Monitor | Oliver (deterministic) | daily cron; CI events | Digest + dashboard, Gate aging/escalation, state reconciliation, CI-failure issues, feedback status write-back | replaces v1 Oliver, with a write path |

**Spec gate mechanics**: merging the spec PR is the approval — a merge hook applies `ready` to the linked issue. Review-with-comments is steering; closing the PR is a veto. `blocked` on the issue is the escape hatch to accept a spec but defer implementation. PRODUCT.md carries numbered testable behavior invariants; TECH.md maps tests 1:1 to those invariants and includes a parallelization assessment.

**Reconciliation**: pure event-driven systems stall invisibly when a trigger misfires (v1's Peter failure). The Monitor's daily pass re-derives expected-vs-actual state and re-fires anything stuck — `sync-execution-state.py`'s logic survives here as the janitor duty.

## Gate map and trust tiers (v1 settings)

| Decision | Setting |
|---|---|
| Publish non-owner feedback as issue | **Gated** (Digest tap) |
| Publish Owner Steering | Gateless |
| Release small+clear Owner-sourced work | Gateless (triage applies `ready`) |
| Release small+clear external work | Gated (`ready` flip) |
| Release large/ambiguous work | Gated (spec PR merge) |
| Merge any implementation PR | Gated — Owner is sole merge authority |
| Persona memory/profile changes | Peer-reviewed in PRs |

Composed property: **no public input reaches code execution without passing through an Owner gesture.** Public GitHub issues opened directly follow the same tiers as feedback: triage may label and ask, but `ready` on externally-sourced work is the Owner's to flip.

The trust ladder is meant to be climbed. The Owner is a temporary merge gate, not a permanent one; delegation advances on reviewer-agreement evidence (below), with large spec'd work and privileged paths staying Owner-gated indefinitely.

## Personas and memory

- **Identity** = GitHub App credential + perspective lens + `author:` label + long-term memory. The three existing minimal-scope Apps carry over. Author labels are applied by machinery, not aspiration (v1 applied zero).
- **Routing**: Peter reads both Profiles at triage and assigns the implementer; the counterpart automatically becomes reviewer — the author≠approver requirement falls out of the pairing. Profiles are seeded from the existing persona prompts (April: application/UX; Plat: platform/CI) and diverge from real history.
- **Memory layout**: `.agents/memory/<persona>/` — `PROFILE.md` (short, machine-readable; what triage reads), `MEMORY.md` index + Memory Blocks (one fact per markdown file, YAML frontmatter with slug + freshness metadata), `journal/` (append-only observations, direct-committed after non-PR work, never consumed as instructions).
- **Write path**: memory and profile changes ride inside the Persona's normal PRs, so the counterpart reviews every self-modification. Journal → Memory Block consolidation ("Dreaming", periodic or triggered) also lands through reviewed PRs. This is the safety boundary against untrusted content laundering itself into future privileged prompts.
- **Enforcement**: `.agents/memory/<own-persona>/**` is carved out of the privileged-path guard; a CI check verifies each App identity only touches its own directory.

## The Owner interface

- **Digest**: one pinned GitHub Discussion — the only live discussion — rewritten daily by the Monitor. Gates sorted by age, each line answerable in one tap (link to the PR, the label flip, the pending feedback). Optimized for GitHub mobile in a 5-minute daily touch.
- **Dashboard**: committed `docs/ops/dashboard.md` + snapshot JSON — the durable, queryable telemetry behind the Digest, and later the API the WorkSpaces app's Attention integration consumes.
- **Steering**: the product's own feedback box (`kind=idea`) or a directly-opened issue; both flow through triage identically. Owner submissions are recognized by `submitter_login` and flow gateless per the gate map.
- **Escalation**: aging Gates rise in the Digest; the Monitor escalates rather than repeating itself verbatim (v1's Fable thread nagged identically 6 of 7 days into the void).

## Safety posture

Carried over from v1 unchanged: three minimal-scope GitHub Apps; env-var sanitization (tokens never reach model context); all GitHub text framed as untrusted data; fork-PR diff exclusion; privileged-path patch guard (`.github/`, `.agents/` outside memory, auth/token/sandbox, release/signing — Owner-merged forever); two-phase mention triage (`safe-to-run-agent` label gate, server-side permission verification) retained as the persona-summoning path; pinned CLI versions.

New in v2:

1. Memory carve-out with per-App directory ownership CI check (above).
2. **Kill switches: per-stage variables (`FACTORY_TRIAGE_ENABLED`, `FACTORY_IMPLEMENT_ENABLED`, …) *and* the global master (`AGENT_AUTOMATIONS_ENABLED`)** — both required to be on for a stage to run.
3. Spend caps as config: per-run token/time budget per stage, daily Factory-wide cap, enforced in the runner, reported in the Digest.
4. Triage's write powers are labels and comments only; implementation starts only from a label event.
5. The future auto-merge class requires a deliberate main-merge ruleset change (`config/github/`) — flagged now so it is a designed decision, not an expedient hack.

The code-writing stages use the following operating switches. Scheduled, event-driven, and manual implementation dispatch requires both the global master and the stage switch; implementation `workflow_dispatch` is triggered by the owner or by the Monitor's own standing-queue sweep, and neither bypasses either switch. `FACTORY_IMPLEMENT_DAILY_CAP` defaults to 6 UTC-day workflow attempts: the claim gate counts owner- **and** sweep-triggered `factory-implement.yml` runs through the Actions API (both identities are trusted for *triggering*, see below), leaves over-budget issues `ready`, and reports the skip in the Digest. `FACTORY_REVIEW_DAILY_CAP` defaults to 12 UTC-day executor attempts, including reruns; the default-branch admit job counts `factory-review-execute.yml` through the Actions API and fails closed before counterpart routing.

An earlier Monitor re-fire lane (#1090) was retired during #1096's hardening review because "an automated dispatcher can't satisfy the owner-actor gate" — the digest's "Ready but unclaimed" list was the interim mitigation, itemizing age so a missed re-fire couldn't be silent. #1148 revives it by decoupling *who triggered this run* from *who admitted the issue*: `scripts/factory-sweep.py` (invoked daily from `factory-monitor.yml`) re-dispatches the oldest already-`ready`+`agent`+`task` issues with no open linked PR, and the workflow trusts its `github-actions[bot]` trigger identity to *attempt* a claim — but `verify_release_actor` in `scripts/factory-implement.py` still independently requires the issue timeline's most recent `ready` label event to be actor-attributed to the repository owner before any work happens. The sweep can never apply `ready` itself, so it only ever re-fires standing admission, never grants new admission.

The sweep's own issue listing is paginated (unlike a bare 100-item request, which would silently cap the standing queue and permanently starve anything older sitting past that point — the exact class of silent stall this issue exists to fix).

A standing queue widens an existing narrow window into a practical one: a sweep can re-fire an issue days after the owner reviewed and released it, versus the near-instant edge-triggered dispatch this replaces, giving anyone who can edit that issue (its author, or a collaborator) real time to change its title/body before the sweep gets to it. `claim()` closes that window with GitHub's `userContentEdits` (the only API surface that exposes issue body/title edit history with an editor — the REST issue timeline has no event for content edits, only `renamed` for titles). That connection's natural order is newest-first, the opposite of most GitHub connections — verified live against this repo's own API — so the check pages *forward* from the most recent edit, collecting everything at-or-after the most recent `ready` event, until it crosses into an edit made before that release (nothing further back could be relevant either) or exhausts history; a single page isn't enough on its own, since a hostile edit can sit behind 50 even-newer (e.g. owner) edits. If anyone but the owner touched the content at or after that release, admission defers and `ready` stays in place pending a fresh owner review, rather than executing against content the owner never actually approved; a null response from GitHub for the edit-history query is treated as a query failure, not "no edits," since a genuinely empty history renders as an empty list, not null.

Both owner-actor and content-staleness pre-filters run in the sweep itself, purely as a budget guard, not the security boundary: without them, relabeling old issues or editing an already-released one would still get correctly declined by `claim()`, but would keep consuming a sweep dispatch slot every single day (since a declined issue stays `ready` for the next sweep to re-pick), indefinitely starving genuinely fresh work of its turn. The stale-scope decline comment is scoped to its release cycle (keyed by the triggering `ready` event's timestamp), so a second hostile edit after the owner re-reviews and re-releases gets its own warning instead of being silently deduped against an earlier, now-resolved one.

Accepted residual risk: the daily cap is a soft cost/operational control, not a security boundary, and isn't reserved atomically — a sweep dispatch racing a near-simultaneous manual dispatch could in principle both pass their own budget check against a not-yet-visible sibling run and land one run over cap. This is a narrow widening of a race class that already existed between concurrent manual/event-driven dispatches; a true fix needs external reservation state GitHub Actions doesn't provide cheaply, so it's accepted rather than engineered around.

The digest also promotes a `ready` issue that outlives one sweep cycle (24h) without moving to `claimed`/`review` into a `queue-age` Threshold breach (worded as "hasn't moved," not "was never dispatched" — a claimed-then-rolled-back issue looks the same from the outside), rather than only the passive list.

| Stage | Global switch | Stage switch | Daily attempt cap | Off behavior |
| --- | --- | --- | --- | --- |
| Implement | `AGENT_AUTOMATIONS_ENABLED` | `FACTORY_IMPLEMENT_ENABLED` | `FACTORY_IMPLEMENT_DAILY_CAP` (6) | No issue-label, manual, or Monitor-sweep dispatch reaches the contributor runtime; the Monitor's sweep never bypasses the release gate |
| Review | `AGENT_AUTOMATIONS_ENABLED` | `FACTORY_REVIEW_ENABLED` | `FACTORY_REVIEW_DAILY_CAP` (12) | No automatic PR review signal reaches a counterpart reviewer |
| Responder | `AGENT_AUTOMATIONS_ENABLED` | `FACTORY_RESPONDER_ENABLED` | Not yet defined | No automatic owner-comment reply is generated or posted |

Attribution is a runtime invariant: autonomous PR creation applies exactly one `author:<agent>` label, while autonomous reviews and comments begin with the acting persona or carry the responder's mechanical anti-loop marker. Shared GitHub account authorship is never treated as sufficient attribution.

## Instruments and dials

The Monitor computes weekly, into dashboard + Digest:

- shipped changes; **touches-per-shipped-change**; median time-in-gate per gate type
- % of shipped work fully autonomous up to PR review
- **reviewer-agreement rate**: Owner merge decision vs reviewing Persona's verdict (and reviewer-vs-reviewer once a third reviewer exists) — the evidence that justifies merge delegation
- token spend per shipped change; spend vs caps

Dials are reviewed monthly against the dashboard. First pre-defined widening (defined now, **disabled**): auto-merge for PRs where all hold — mechanical change class (docs, deps, test-only, config-as-code) · implementer ≠ reviewer and reviewer approved · CI green · evidence attached · no privileged paths.

## Cleanup wave (part of M1)

- **Discussions**: close all 25 with a short disposition comment linking this plan. The Fable daily-recommendation thread retires — its function is the Digest. One new pinned Digest discussion becomes the only live thread. Fossil `[idea]` threads are not auto-converted; anything still alive re-enters via Steering.
- **Issues**: one interactive-lane batch re-triage of the 52 `agent` issues — shipped-detection first (`rg` acceptance criteria against the tree; the tracker lags the code), then a single disposition table (close-as-shipped / close-as-stale / relabel / `idea`) approved by the Owner in one sitting.
- **Machinery**: one PR wave deletes the cron-contributor workflows (`agent-april.yml`, `agent-plat.yml` schedules + selector runtime), Peter's keyword trigger, and the wake-up model; `sync-execution-state.py` donates its logic to the Monitor; `docs/development/agent-team.md` is rewritten as the Factory doc. Kept: `_evidence.yml`, App identities, mention flow, evidence lane, label vocabulary.

## Milestones

- **M0 — Decisions on paper** *(this session)*: this plan, three ADRs, glossary (`CONTEXT-MAP.md`, `docs/agents/GLOSSARY.md`), doc-nav row. Done when the PR merges.
- **M1 — Eyes + broom**: Monitor v1 (daily Digest posted, dashboard committed by workflow — write path proven, Gate aging, reconciliation janitor) + the cleanup wave. Done when: a Digest exists and updates daily; `docs/ops/` shows a current timestamp; open discussions = 1; the disposition table has been approved and applied; v1 crons are deleted.
- **M2 — Front door**: Triage stage on issue-opened + feedback-poll cron; worker `status='new'` service endpoint; trust tiers enforced; feedback status write-back. Done when: an Owner feedback submission flows gateless to a `ready` issue with no human touch; a non-owner submission waits in the Digest.
- **M3 — Hands**: Implement + Review stages on small `ready` work; Profile-based routing; memory v1 (journal, blocks, PR-carried updates, ownership CI check). Done when: the first Factory-authored PR merges carrying machinery-applied `author:` labels, counterpart review, evidence, and a memory diff.
- **M4 — Spec gate**: `spec` label, spec-only PRs, merge→`ready` hook. Done when one large item flows steering → spec PR → merge → `ready` → implementation PR.
- **M5 — Instruments and dials**: full metric suite live; monthly dial-review ritual; auto-merge class formally specified, disabled.
- **M6+ — Earned autonomy** (sequenced later, by evidence): third agent reviewer (codex; `codex-review-loop` machinery exists) → reviewer-quorum auto-approve on mechanical classes; Dreaming; app-integrated Digest via Attention; skill-optimization outer loop **with explicit exit criteria** (the named failure mode of graderless loops is token-burning local-maxima chasing); integration branches for large work; feedback-publication widening.

The Factory never builds itself autonomously: M1–M4 are Interactive Lane work, and even at M6 the Factory's own code changes only through fully-gated PRs the Owner merges.

## Experiment register (observe, don't design yet)

- **Persona divergence** — a first-class research goal: rich journals, periodic published self-retrospectives (a Dreaming output), routing history as data. What does months of accumulated, peer-reviewed memory do to two initially-similar agents?
- **Integration-branch approach** for large spec'd work — deliberately unresolved; observe where big PRs strain the single-PR flow and let the mechanism emerge.
- **Third-reviewer quorum** — which change classes reach reviewer-agreement rates that justify delegation, and how fast.
- **Feedback loop closure** — surfacing "your feedback shipped" back through the product once `status='resolved'` write-back exists.

## Operational lessons

Close-out procedures learned in live operation (2026-07-17 dogfood). These are owner-side runbook entries, not design changes.

1. **A stale CHANGES_REQUESTED is superseded by re-dispatch, not dismissal.** A counterpart verdict anchors to the state it reviewed; a fix that only edits the PR body (evidence attestation, Mergeability fields) fires no event that would prompt a re-review, so the verdict sits stale. The remedy is `gh workflow run factory-review.yml -f pr_number=<N>` — the counterpart re-reviews and supersedes its own verdict, keeping the reviewer-agreement record intact. Dismissing the review through the owner API is the anti-pattern (and is blocked): it erases the reviewer's verdict instead of letting the reviewer replace it.
2. **Comment- and label-triggered workflows execute from the default branch.** `issue_comment`, label events, and `workflow_dispatch` all run the workflow definition on `main`, not the one in your checkout. Pre-flight a workflow change against what `main` currently contains; triggering the event from a feature branch exercises the old definition, and the new one only takes effect at merge.
3. **The evidence-status body block is the owner's attestation surface.** When evidence items sit `[blocked]` and the owner has verified them out of band, the close-out is: edit the item statuses in the PR's `## Evidence Status` block, strip the `blocked` label, and re-dispatch the review (lesson 1). On the counterpart's superseding approval, the runtime applies `mergeable` to the PR and its source issue — no manual label flip needed beyond removing `blocked`.

## References

- Live-state audit, infra deep-dive, feedback-feature map: session artifacts, 2026-07-12 (summarized in "Why v1 stalled").
- Warp: [the automatic triage skill](https://www.warp.dev/blog/how-to-build-a-cloud-software-factory-the-automatic-triage-skill) · [three skills for spec-driven development](https://www.warp.dev/blog/three-skills-for-spec-driven-development) · [skill optimization loop](https://www.warp.dev/blog/building-a-skill-optimization-loop) · [demo repo](https://github.com/warpdotdev-demos/cloud-factory-demo) · [common-skills](https://github.com/warpdotdev/common-skills)
- Factory.ai: [Factory 2.0](https://factory.ai/news/software-factory) · [Signals](https://factory.ai/news/factory-signals)
