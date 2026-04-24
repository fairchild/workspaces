---
status: pending
category: plan
priority: P1
created: 2026-04-23
related_decision: docs/decisions/terminal-multiplexing.md
---

# Desktop Continuity — Pick Up Where You Left Off

## Problem

When a user closes the Workspaces app and reopens it later, terminals lose in-flight state: cwd, env, scrollback, and any non-detached process. The current two-pane model and the chosen tmux-primary multiplexing model both address *layout composition*, not *continuity across the application's own lifecycle*.

Web has solved an analogous problem via persistent-sandbox snapshot/restore (#277, see `backlog/done/persistent-sandbox-conversation-continuity_plan.md`). Tmux-in-sandbox (#311 → #324) gives reattach within a running sandbox. Neither solves the desktop case where the host process itself stops.

## Why this plan exists

`docs/decisions/terminal-multiplexing.md` named continuity as the question that drove the multiplexing decision. This plan exists so that the decision is honest: tmux primary alone does not deliver across-session continuity on desktop, and we are tracking that gap as its own work.

## Goal

Make "close the laptop, reopen tomorrow, pick up where you left off" a working desktop default for at least one well-defined daily-driver scenario.

## Possible approaches (do not pre-decide)

1. **Tmux as continuity.** Once tmux primary ships, every workspace terminal lives inside a tmux session whose state survives Ghostty surface restarts. Restoring on app reopen reattaches via `tmux attach`. Limitation: only survives if the tmux server itself survives, which depends on user-shell daemonization and OS reboot policy.
2. **Restore manifest.** Persist per-workspace terminal cwd, env keys, and last-N scrollback lines. Replay on app open. Cheap; loses in-flight processes.
3. **Per-workspace launchd daemon.** Run a background tmux server per workspace under launchd so the server survives logouts. Higher infra cost; clearest semantics.
4. **Hybrid.** Tmux for survival of in-flight processes within the same OS session; restore manifest for cross-reboot recovery.

## Inputs to gather before promotion

- Confirm what tmux state actually survives Ghostty surface restart vs full app restart vs full OS reboot, on real hardware.
- Re-read `Sources/WorkspaceManagerCore/Services/WorkspaceService.swift` for current per-workspace lifecycle hooks.
- Re-read `backlog/done/persistent-sandbox-conversation-continuity_plan.md` for design lessons that transfer from web's snapshot/restore work.
- Define one concrete daily-driver scenario the first phase must pass (e.g., "agent chat in workspace A is mid-stream when I sleep my laptop; tomorrow morning I open the app and the agent stream resumes within 3 seconds").

## Trigger

Promote to a session of `/improve-codebase desktop` after `backlog/tmux-support_plan.md` Phase 1 ships, or sooner if the continuity gap blocks a real daily-driver use case before then.

## Non-goals

- Not session sharing across machines.
- Not file-system snapshots; only terminal state.
- Not a replacement for git worktree state; the worktree IS the persistent state.
