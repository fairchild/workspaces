---
status: decided
date: 2026-07-12
decision: factory-persona-memory
related:
  - docs/development/agent-factory-v2-plan.md
  - docs/decisions/factory-event-driven-stages.md
  - docs/agents/GLOSSARY.md
---

# Personas manage their own memory through peer-reviewed PRs

## Decision

**Each Persona owns a versioned, public memory at `.agents/memory/<persona>/`: a `PROFILE.md` (short machine-readable self-description that Triage reads when routing implementer vs reviewer), a `MEMORY.md` index over Memory Blocks (one fact per markdown file, YAML frontmatter carrying a short slug and freshness metadata), and an append-only `journal/`.**

Write paths are asymmetric by design:

- **Memory Blocks and Profile change only inside the Persona's normal PRs**, where the counterpart Persona reviews them — every self-modification is peer-reviewed for free.
- **The Journal is the only direct-write surface**: append-only observations committed after non-PR work (triage runs, reviews). Journals are never consumed as instructions; consolidation of journal → Memory Blocks ("Dreaming", periodic or triggered) lands through the reviewed-PR path.
- `.agents/memory/<own-persona>/**` is carved out of the privileged-path patch guard; a CI check enforces that each GitHub App identity only touches its own directory. Everything else under `.agents/` remains privileged.

Specialization is emergent, not configured: Profiles are seeded from the existing persona lenses (April: application/UX; Plat: platform/CI) and diverge from real history. Persona divergence over months is an explicit research goal — journals are rich, and periodic self-retrospectives are a designed Dreaming output.

## Why

v1 had zero cross-run memory: each wake-up re-derived "what I did" from GitHub, capped at three threads. Agents could not build judgment, notice repetition, or specialize. Memory is also the safest first form of self-modification — additive, reviewable, low blast radius — and a prerequisite for routing-by-strength rather than routing-by-rule.

The threat model drove the write-path asymmetry: memory is agent-written text fed back into trusted context later. A Persona processes untrusted public content (issues, feedback); an unreviewed write channel into files that shape future privileged prompts would let injected instructions launder themselves into persistent trust. Routing all behavior-shaping writes through counterpart-reviewed PRs closes that channel at zero ceremony cost, since implementation PRs are peer-reviewed anyway.

## Trade-off accepted

Freshness vs safety: PR-carried memory lags (a lesson learned mid-task lands when the PR does), and non-PR stages would otherwise have no memory at all — hence the append-only Journal side channel, which trades a small unreviewed surface (observations, quarantined as data) for continuous capture. Public memory on a public repo is deliberate: auditable specialization, at the cost of the Personas having no private state.
