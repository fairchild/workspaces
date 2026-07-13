---
status: decided
date: 2026-07-12
decision: factory-event-driven-stages
related:
  - docs/development/agent-factory-v2-plan.md
  - docs/decisions/factory-label-control-plane.md
  - docs/agents/CONTEXT.md
---

# Event-fired Stages replace scheduled persona wake-ups

## Decision

**The Factory pipeline is six Stages — Triage, Spec, Implement, Review, Verify, Monitor — each fired by a label event, never by a schedule that asks an agent to find something to do. Only two crons survive: the Monitor's daily pulse (Digest, Gate aging, state reconciliation) and a feedback poll. An idle Factory does nothing.**

Two mechanics inside this:

1. **Spec-merge is the release gate.** Large/ambiguous work gets a `spec` label; the Spec stage opens a spec-only PR (`specs/<slug>/PRODUCT.md` + `TECH.md`); merging that PR applies `ready` to the linked issue via a merge hook. One gesture reviews the direction and releases implementation. `blocked` on the issue defers implementation after an accepted spec.
2. **Personas are rebound to roles, never scheduled.** April/Plat form the implement/review pair (whichever implements, the other reviews — satisfying GitHub's author≠approver rule); Peter runs Triage and Spec; Oliver names the deterministic Monitor. The wake-up/selector runtime is retired.

## Why

v1's contributor runtime allowed exactly one action per wake-up, chosen by strict priority where reviewing always outranked claiming work — and in a repo whose Interactive Lane generates PRs constantly, something reviewable always existed. Proposing a new idea was the terminal fallback when idle; stale-thread cleanup was unreachable dead code. Result: April authored 2 PRs ever, Plat 0, against 106 reviews; two personas structurally biased toward accumulating conversation and barred from finishing.

Scheduled "find work" agents also generate supply without demand — new proposals queued into an approval funnel that didn't scale. Event-fired stages invert this: pace comes from Inlets (feedback, Steering, operational signals) feeding Triage, so throughput tracks real demand.

The spec-merge gate collapses v1's two sequential human gestures (keyword reply, then 👍) into one action on the Owner's proven surface: he merges PRs in a median of 18 minutes and visits Discussions never. A separate second gesture is the exact failure mode that starved v1.

## Trade-off accepted

Pure event-driven systems stall invisibly when a trigger misfires — v1's planner failed silently on its one genuine trigger. Mitigation is structural: the Monitor's daily reconciliation pass re-derives expected-vs-actual state and re-fires anything stuck (`sync-execution-state.py`'s logic survives as this janitor duty). The persona fiction also carries a seduction cost — v1's most designed artifact was the team narrative, which fossilized while unglamorous machinery worked. The guard: a Persona exists only when an event routes work to it.
