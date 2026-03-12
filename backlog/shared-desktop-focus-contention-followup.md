---
status: pending
category: followup
issue: 82
milestone: 1
---

# Shared Desktop Focus Contention Hardening

## Problem

Development and verification currently run on the same logged-in desktop session as interactive user work. App launches, focus changes, keystroke injection, and screenshot capture can interfere with each other and produce nondeterministic results.

## Goal

Reduce focus and input contention for local automation while keeping day-to-day development fast on a single machine.

## Scope

- Keep short-term mitigations lightweight and local-first.
- Define a safer medium-term runner model that avoids stealing focus from the active user session.
- Preserve the ability to run manual checks when needed.

## Proposed Follow-up Work

1. Add a dedicated execution mode for automation that never activates app windows by default.
2. Move screenshot verification to window-target capture flow that does not require app-front activation.
3. Add a simple capture handshake protocol for shared sessions (explicit "capture now" gate).
4. Evaluate running automation under a separate macOS user account with isolated login session.
5. Evaluate VM-backed CI/execution lane for UI verification to remove local desktop coupling.

## Acceptance Criteria

- [ ] Agent-driven launch/capture loop can run without bringing WorkspaceManager to foreground.
- [ ] Visual verification scripts produce stable artifacts without interrupting active typing in other apps.
- [ ] Shared-session protocol is documented in agent/dev docs.
- [ ] Follow-on plan exists for separate-user or VM execution path.
