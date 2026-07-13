---
name: fable-orchestrator
description: >
  Fable — the daily orchestrator. Surfaces one recommendation for the owner by
  ranking what competes for their attention (merge-ready PRs, ideas awaiting
  approval), always pointing at an existing approval surface. Use when running
  the daily orchestration pass or reasoning about the owner's next action.
---

> **Retired:** The `agent-fable.yml` workflow was retired on 2026-07-12. The
> Factory Digest now replaces Fable's daily recommendation.

# Fable — Daily Orchestrator

Fable answers one question each day: **what is the single highest-value thing the owner should do next?** It reads live project state, ranks the candidates, and names one action plus a short ranked tail — then stops. Fable never acts and never invents an approval channel; every recommendation points at a surface the owner already uses (merge this PR, reply "plan it" on that idea), preserving the owner-as-sole-authority invariant in `docs/development/agent-owner-protocol.md`.

## Run it

```bash
uv run scripts/fable-orchestrator.py                 # gather live, print the recommendation
uv run scripts/fable-orchestrator.py --json          # structured output
uv run scripts/fable-orchestrator.py --post          # append to the running discussion thread
uv run scripts/fable-orchestrator.py --fixtures-dir fixtures/fable-orchestrator   # replay, no network
```

The `agent-fable.yml` workflow runs it daily (gated by `AGENT_AUTOMATIONS_ENABLED`): a dry-run preview, then `--post` to the running **[orchestrator] Fable — Daily Recommendation** discussion (created on first post).

## How it ranks (v1, deterministic)

Deliberately Oliver-style — deterministic, never hallucinates — so the ranking can earn trust before an LLM synthesis layer is added (v2).

| Candidate | Why it ranks there | Owner action |
|-----------|--------------------|--------------|
| **Merge-ready PR** (`mergeable` label or `APPROVED`, not draft) | Work is done; only the owner's merge gate remains — pure throughput | Merge the PR |
| **Idea awaiting approval** (`[idea]` title prefix, not `[endorsed]`) | A proposal is blocked on the owner's approve-to-plan decision | Reply "plan it" on the discussion → Peter plans it |
| **PR with changes requested** | Stalled until someone responds | Look at the PR |

Among equal scores, the freshest wins (a new idea is a live decision; a long-unendorsed one is likelier stale than urgent). `[idea]` is matched as a title **prefix**, so rambling posts that merely mention it are ignored.

## Boundaries and next steps

- **Read-only.** Fable gathers and recommends. The owner acts through existing mechanics; `sync-execution-state.py` and the contributors already carry execution once approval lands.
- **Not yet surfaced:** user feedback awaiting triage (wire in once the feedback-store agent API token is live) and Peter-planned issues awaiting the 👍. Both are natural next candidate sources.
- **v2:** an LLM synthesis layer that writes the recommendation as prose and weighs cross-surface context, once the deterministic ranking is trusted.

See `references/fable.md` for the persona.
