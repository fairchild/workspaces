---
status: pending
category: plan
priority: P1
---

# Terminal Multiplexing Direction — Product Decision Session

## Purpose

Lock the multiplexing model before we invest more in either direction. The roadmap currently carries two detailed plans for the same job — a native pane tree (`backlog/pane-tree-tiling_plan.md`) and a tmux-backed model (`backlog/tmux-support_plan.md`) — and the roadmap itself says "do not productize both deeply at the same time." That decision is now the blocker, not the implementation.

## Context

- Current state: two-pane Ghostty split works for basic multiplexing. Split/focus/resize/equalize are shipped. Agents and users already lean on it daily.
- `pane-tree-tiling_plan.md`: native tree model, deep SwiftUI integration, feature-flag rollout, fits our design language. Higher build cost; we own the whole tree.
- `tmux-support_plan.md`: tmux per worktree, reattach semantics, leans on 30 years of battle-tested behavior. Lower build cost; different UX model (tmux-shaped, not app-shaped).
- The clarified capability from #311 → #324: tmux gives reattach, not snapshot/restore. Persistent-sandbox snapshot/restore already exists in web via #277. Native continuity on desktop still wants something.

## Scope of this session

**In scope** — pick one of:
1. Pane-tree primary; tmux stays as a per-user escape hatch (not first-party).
2. Tmux primary; pane-tree deferred indefinitely.
3. Hybrid with a clear line: tmux for continuity/reattach, pane-tree for layout composition.
4. Defer both; freeze at current two-pane for another quarter.

**Out of scope** — implementation. This session produces the decision and its rationale, not code.

## Desired artifact

One short decision record under `docs/decisions/` (create the folder if it does not exist) titled "Terminal multiplexing model." The record should capture:
- the decision and its scope
- the alternatives considered and why they lost
- the conditions under which the decision should be revisited
- which of the two existing plans stays active and which gets archived to `backlog/done/`

## Inputs to gather before the session

- Re-read the two plan files in full
- Re-read `backlog/terminal-architecture-followups.md` (interacts with both)
- Skim recent terminal-related PRs (#288, #299, #311/#312/#315, #324) for current UX assumptions
- Ask Michael: what is the daily-driver use case that either model must get right?

## Non-goals

- Not a full tiling WM specification
- Not a replacement for the current two-pane model until the chosen plan ships
- Not a decision about remote terminal continuity — that is snapshot/restore (already live in web) and is separate

## Trigger

Run this as its own `/improve-codebase desktop` session once roadmap grooming lands. Pair it with a short human conversation — this is a judgment call, not a research-only task.
