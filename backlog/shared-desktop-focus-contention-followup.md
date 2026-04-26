---
status: phase-1-complete
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

1. ~~Add a dedicated execution mode for automation that never activates app windows by default.~~ **Done** — `AppActivationPolicy` (PR #374) gates all `NSApp.activate(ignoringOtherApps:)` calls — launch *and* runtime — behind `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1` and `CI`.
2. ~~Move screenshot verification to window-target capture flow that does not require app-front activation.~~ **Done** — `scripts/capture-window.sh` shipped earlier; uses `screencapture -l <window-id>` with `CGWindowListCopyWindowInfo` lookup, no activation required.
3. Add a simple capture handshake protocol for shared sessions (explicit "capture now" gate). *Phase 2.*
4. Evaluate running automation under a separate macOS user account with isolated login session. *Phase 2.*
5. Evaluate VM-backed CI/execution lane for UI verification to remove local desktop coupling. *Phase 2 — partially overlapping with the Lume runner work tracked separately in `backlog/lume-runtime-architecture-followups_followup.md`.*

## Acceptance Criteria

- [x] Agent-driven launch/capture loop can run without bringing WorkspaceManager to foreground. (PR #374 + `capture-window.sh`)
- [x] Visual verification scripts produce stable artifacts without interrupting active typing in other apps. (Same.)
- [ ] Shared-session protocol is documented in agent/dev docs. *Partially — `CLAUDE.md` "App Activation Policy" section covers the activation gate; explicit handshake protocol still pending.*
- [ ] Follow-on plan exists for separate-user or VM execution path. *Phase 2.*

## Phase 2 — remaining work

The remaining items (capture handshake, separate user account, VM-backed CI lane) are quality-of-life improvements rather than P0 blockers. They drop to P2 in the priority bands now that the core "agent-driven loop never steals focus" property holds. Promote back to P1+ when a concrete daily-driver scenario forces the issue.
