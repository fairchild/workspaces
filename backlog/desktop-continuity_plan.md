---
status: active
category: plan
priority: P1
created: 2026-04-23
related_decision: docs/decisions/terminal-multiplexing.md
branch: codex-continuity-dimension
---

# Desktop Continuity — Pick Up Where You Left Off

## Problem

When a user closes the Workspaces app and reopens it later, terminals lose in-flight state: cwd, env, scrollback, and any non-detached process. The current two-pane model and the chosen tmux-primary multiplexing model both address *layout composition*, not *continuity across the application's own lifecycle*.

Web has solved an analogous problem via persistent-sandbox snapshot/restore (#277, see `backlog/done/persistent-sandbox-conversation-continuity_plan.md`). Tmux-in-sandbox (#311 → #324) gives reattach within a running sandbox. Neither solves the desktop case where the host process itself stops.

## Why this plan exists

`docs/decisions/terminal-multiplexing.md` named continuity as the question that drove the multiplexing decision. This plan exists so that the decision is honest: tmux primary alone does not deliver across-session continuity on desktop, and we are tracking that gap as its own work.

## Goal

Make "close the laptop, reopen tomorrow, pick up where you left off" a working desktop default for at least one well-defined daily-driver scenario.

## First-phase continuity contract

Scenario: a user opens a local repo or local workspace terminal, works inside a deterministic Workspaces tmux session for that terminal's launch directory, quits and reopens the app, and lands back on the same terminal target. If the OS tmux server survived, Workspaces reattaches to the same tmux session with its live cwd, panes, scrollback, and running process. If the tmux server did not survive, Workspaces falls back to the persisted terminal continuity manifest and relaunches the same terminal target from the last known launch directory, or from the target root if that directory disappeared.

This is intentionally narrower than full shell resurrection. It makes the same-OS-session case genuinely continuous and makes cross-reboot recovery explicit instead of pretending in-flight processes can be recreated.

## Possible approaches (do not pre-decide)

1. **Tmux as continuity.** Once tmux primary ships, every workspace terminal lives inside a tmux session whose state survives Ghostty surface restarts. Restoring on app reopen reattaches via `tmux attach`. Limitation: only survives if the tmux server itself survives, which depends on user-shell daemonization and OS reboot policy.
2. **Restore manifest.** Persist per-workspace terminal cwd, env keys, and last-N scrollback lines. Replay on app open. Cheap; loses in-flight processes.
3. **Per-workspace launchd daemon.** Run a background tmux server per workspace under launchd so the server survives logouts. Higher infra cost; clearest semantics.
4. **Hybrid.** Tmux for survival of in-flight processes within the same OS session; restore manifest for cross-reboot recovery.

First phase chooses the hybrid path because it has the clearest semantics: tmux preserves real process state when the server exists, and the manifest defines the honest fallback when it does not.

## Implementation notes

- `TerminalContinuityManifest` persists the last local repo/workspace terminal target, normalized root path, launch path, selected terminal multiplexing mode, deterministic Workspaces tmux session name for the launch path, and timestamp in app storage.
- Restored repo/workspace terminal launches consult that manifest before falling back to the target root directory.
- Remote/provider-backed workspaces are out of this first slice because their lifecycle continuity belongs to the provider-specific terminal launch contract.
- `scripts/tmux-continuity-probe.sh` provides a manual start/check/cleanup loop for recording tmux survival across app restart, sleep/wake, logout, and reboot boundaries.

## Inputs to gather before promotion

- Confirm what tmux state actually survives Ghostty surface restart vs full app restart vs full OS reboot, on real hardware. Use `scripts/tmux-continuity-probe.sh start <path> <label>` before the boundary and `scripts/tmux-continuity-probe.sh check <path> <label>` after it.
- Re-read `Sources/WorkspaceManagerCore/Services/WorkspaceService.swift` for current per-workspace lifecycle hooks.
- Re-read `backlog/done/persistent-sandbox-conversation-continuity_plan.md` for design lessons that transfer from web's snapshot/restore work.
- Define one concrete daily-driver scenario the first phase must pass (e.g., "agent chat in workspace A is mid-stream when I sleep my laptop; tomorrow morning I open the app and the agent stream resumes within 3 seconds").

## Trigger

Promote to a session of `/improve-codebase desktop` after `backlog/tmux-support_plan.md` Phase 1 ships, or sooner if the continuity gap blocks a real daily-driver use case before then.

## Non-goals

- Not session sharing across machines.
- Not file-system snapshots; only terminal state.
- Not a replacement for git worktree state; the worktree IS the persistent state.
