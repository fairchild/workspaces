---
status: done
category: followup
pr: null
branch: codex/refinement-gate-hardening
score: null
retro_summary: Added coarse creation phases to the service and inline repo-scoped progress state in the sidebar without changing the persistence model.
completed: 2026-03-07
---

# Workspace Creation Progress Indicator

## Outcome

This follow-up landed on mainline as part of the refinement-gate closure:

- `WorkspaceService.createWorkspace(...)` now emits coarse progress phases.
- `SidebarView` now shows repo-scoped inline progress immediately after submit.
- Duplicate create actions are blocked while a repo already has work in flight.
- Success and failure paths both clear state correctly.

## Notes

- The implementation uses coarse phases (`preparing`, `copyingRepository`, `creatingBranch`, `runningSetupScript`, `finished`) rather than a true byte-level progress bar.
- No additional persistent model changes were required.
