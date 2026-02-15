---
status: pending
category: followup
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# Refinement and Performance Hardening

## Problem

Core host-terminal workflows are now functional and releaseable, but quality risk remains in three areas:

- Performance is improved but not yet measured with durable baselines.
- Session switching behavior needs stronger regression protection for reuse and focus restore.
- Session surface lifecycle policy is implicit, which can create memory-risk ambiguity as usage scales.

## Goal

Deliver a refinement-first hardening pass before M2 so current behavior is fast, deterministic, and operationally well understood.

## Scope

1. Add production signposts and measure baseline latency.
2. Add regression tests for session reuse/focus under rapid switching.
3. Decide and implement session surface memory policy, or explicitly document no-cap rationale.

## Work Items

### 1) Signposts and Baseline Measurement

- Add signposts around:
  - launch to first terminal prompt
  - repo hydration from `~/code`
  - repo click to focused terminal input
- Run Instruments baselines and capture results in a short report committed to the repo.
- Define target thresholds and note current variance across sample runs.

### 2) Session/Focus Regression Coverage

- Add tests covering:
  - session reuse for repeated repo/workspace clicks
  - focus restoration to correct terminal surface
  - rapid click-switching between multiple repos/workspaces
- Validate no session duplication under canonical-path-equivalent selections.

### 3) Session Surface Memory Policy

- Decide one of:
  - implement lightweight inactive-surface cap (LRU), or
  - keep unbounded for now with explicit rationale and monitoring triggers
- Document policy in architecture docs and note operational guardrails.

## Acceptance Criteria

- [ ] Signposts present for launch, hydration, and click-to-focus paths.
- [ ] Baseline report checked in with measured timings and environment notes.
- [ ] Regression tests added and passing for session reuse/focus behavior.
- [ ] Memory policy decision implemented or explicitly documented with rationale.
- [ ] `swift test` passes after changes.

## Verification

- `swift test`
- Targeted interaction verification in app:
  - launch -> host prompt responsiveness
  - repo click -> focused ready-to-type terminal
  - repeated switching restores prior live sessions

## References

- `/Users/fairchild/code/workspaces/backlog/ROADMAP.md` (Refinement Gate)
- `/Users/fairchild/code/workspaces/backlog/vz-tahoe-execution-brief-plan.md` (M2+ follow-on)
