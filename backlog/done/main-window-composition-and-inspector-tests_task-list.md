---
status: done
category: followup
pr: null
branch: codex/refinement-gate-hardening
score: null
retro_summary: Extracted the first coordinator/controller seams and added inspector/right-pane regression coverage without changing visible behavior.
completed: 2026-03-07
---

# Main Window Composition + Inspector Tests

## Outcome

This work landed on mainline as part of the refinement-gate closure:

- Extracted the first orchestration seams out of `ContentView`:
  - `MainSelectionCoordinator`
  - `TerminalFocusCoordinator`
  - `SplitRoutingController`
  - `InspectorStateController`
- Added dedicated regression coverage for inspector visibility/pruning and right-pane state persistence.
- Kept the root window behavior stable while making the app-level test surface materially better.

## Residual Debt

`ContentView.swift` is still one of the largest files in the app, and broader maintainability work remains. That follow-up is now tracked in `backlog/main-window-sidebar-maintainability_followup.md`.
