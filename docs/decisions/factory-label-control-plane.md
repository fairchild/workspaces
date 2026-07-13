---
status: decided
date: 2026-07-12
decision: factory-label-control-plane
related:
  - docs/development/agent-factory-v2-plan.md
  - docs/agents/CONTEXT.md
  - docs/agents/triage-labels.md
---

# Labels and PRs are the Factory's only control plane

## Decision

**All Factory state lives in the GitHub-native state machine the repo already owns — issue labels (lane/state/gate axes per `docs/agents/triage-labels.md`), issue assignment, and PR review state. Every agent is a stateless skill fired by a state transition. Every human Gate is exactly one of: a label flip, a PR review, or a merge. No gate or trigger ever parses comment keywords or scrapes reactions.**

This kills, deliberately: the `plan it`/`approved` keyword trigger for planning; the 👍-on-summary-comment execution gate; Discussions as a decision surface; and the `[idea]` → `[idea][endorsed]` title-tag lifecycle (replaced by the existing `idea` label). GitHub Discussions are demoted to a single pinned Digest thread the Monitor rewrites; agent deliberation that should change outcomes must terminate in an agent flipping a label or editing an issue.

## Why

The 2026-07-12 audit showed v1 failed at conversion, not execution. Execution: 141 agent-lane PRs merged in 60 days, 18-minute median time-to-merge. Conversion: the planner's keyword trigger fired genuinely once ever (2026-03-22) and failed silently that time; Discussions went fully silent on June 9; 22 of 25 open discussions were idle >14 days; zero `[idea]` discussions converted in 60 days.

The Owner's revealed preference is the design's ground truth: PR review requests get processed in minutes; Discussions never. Keyword parsing and reaction scraping also fail invisibly — an edited comment, a login mismatch, or a workflow failure leaves no trace that a decision was made but not consumed. Label events are durable, replayable, and reconcilable.

## Trade-off accepted

The conversational "team room" — agents visibly deliberating, the Owner participating in threads — was part of the original intent and is lost as a control surface. The audit ruled on its actual value: it was write-only theater. Legibility is rebuilt deliberately as an observability surface (Digest + dashboard) rather than preserved as the control plane. Multi-agent deliberation remains possible as an experiment, but never on the critical path of a decision.
