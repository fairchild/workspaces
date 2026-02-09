---
status: pending
category: followup
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# Workspace Creation Progress Indicator

## Problem

Workspace creation can take significant time for large repositories (for example, when copying large generated directories). Today the UI appears idle during copy, which makes the app feel stuck.

## Goal

Add a visible progress/loading state while a workspace is being created so users understand the operation is active and can estimate when it will finish.

## Scope

- Show an in-progress state from the moment "Create" is submitted until success/failure.
- Surface at least one of:
  - elapsed time, or
  - coarse progress phases (copying repo, creating branch, running setup script).
- Keep error handling integrated with existing alert flow.

## Proposed Implementation

1. Add creation state in `SidebarView` (e.g., `isCreatingWorkspace`, `creationPhase`, `creationStartedAt`).
2. Disable duplicate create actions while creation is in flight.
3. Render a non-blocking progress UI (sheet overlay, inline footer, or modal progress view).
4. Emit phase updates from `WorkspaceService.createWorkspace(...)` using a lightweight callback or typed status enum.
5. Clear progress state on success and failure paths.

## Acceptance Criteria

- [ ] User sees immediate feedback after clicking "Create".
- [ ] UI does not appear frozen during long copies.
- [ ] Progress state clears correctly on both success and failure.
- [ ] Existing tests still pass; add targeted tests for state transitions if practical.

