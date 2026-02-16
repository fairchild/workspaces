---
status: done
category: followup
pr: null
branch: main
score: null
retro_summary: "Added production latency signposts, expanded session regression coverage, and documented unbounded surface policy with guardrails."
completed: 2026-02-15
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

- [x] Signposts present for launch, hydration, and click-to-focus paths.
- [x] Baseline report checked in with measured timings and environment notes.
- [x] Regression tests added and passing for session reuse/focus behavior.
- [x] Memory policy decision implemented or explicitly documented with rationale.
- [x] `swift test` passes after changes.

## Verification

- `swift test`
- Targeted interaction verification in app:
  - launch -> host prompt responsiveness
  - repo click -> focused ready-to-type terminal
  - repeated switching restores prior live sessions

## Completed Work (2026-02-15)

1. Signposts + baseline capture
- Added production signposts in `PerformanceSignposts` for:
  - `LaunchToFirstPrompt`
  - `RepoHydration`
  - `RepoClickToFocusedInput`
- Wired signpost lifecycle into launch, auto-hydration, and terminal focus handoff code paths.
- Added reproducible baseline script: `/Users/fairchild/code/workspaces/scripts/perf-baseline.sh`.
- Checked in baseline report:
  - `/Users/fairchild/code/workspaces/docs/performance/refinement-baseline-2026-02-15.md`

2. Session/focus regression coverage
- Expanded `HostTerminalSessionCoordinator` tests for:
  - rapid repeated switching + active-session restoration
  - canonical-path-equivalent no-duplication (symlink + `..` path forms)

3. Session surface memory policy
- Decision: keep surfaces unbounded for now.
- Implemented explicit guardrail logging in `HostTerminalSurfaceStore` with revisit threshold (`>= 24` surfaces).
- Documented rationale + revisit triggers in:
  - `/Users/fairchild/code/workspaces/ARCHITECTURE.md`

## Verification Results

- `swift test`: pass (71 tests)
- `swift build`: pass
- Perf baseline capture:
  - `./scripts/perf-baseline.sh 5 8`
  - report and metrics committed in docs/performance report above
  - attempted `xctrace` captures (`Time Profiler`, `SwiftUI`) reported local ktrace session errors; documented in report

## References

- `/Users/fairchild/code/workspaces/backlog/ROADMAP.md` (Refinement Gate)
- `/Users/fairchild/code/workspaces/backlog/vz-tahoe-execution-brief-plan.md` (M2+ follow-on)
