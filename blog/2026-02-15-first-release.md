# Workspaces Milestone: First Public Release

Date: 2026-02-15

Today we published our first signed and notarized Workspaces release.

Release:
- Tag: `workspaces-v0.1.0-main.8`
- Release URL: https://github.com/fairchild/workspaces/releases/tag/workspaces-v0.1.0-main.8
- Artifacts:
  - `WorkspaceManager-0.1.0.dmg`
  - `WorkspaceManager-latest.dmg`

## What We Shipped So Far

- Host-terminal-first default behavior on app launch.
- Default launch directory resolution:
  - `~/code`
  - fallback to `$HOME/code`
  - fallback to `$HOME`
- Main terminal remains host-pinned by default.
- Selecting items in the sidebar does not silently retarget the main terminal context.
- Repository auto-discovery from `~/code` (non-recursive).
- Repo click opens or resumes a persistent host terminal session in that repo directory.
- Workspace click opens or resumes a persistent host terminal session in that workspace directory.
- One-click return to the host portfolio terminal.
- Visual live-session indicators in the sidebar.
- Release automation for building, signing, notarizing, and publishing DMG artifacts.

## What We Learned

- Fast context switching and session persistence are core to product quality.
- Visibility matters: live-session indicators reduce ambiguity when many repos are active.
- Release reliability depends on repeatable credential setup and hardened CI workflow steps.

## Next Focus

Before expanding feature breadth, we are prioritizing refinement and performance hardening:

1. Add signposts and baseline measurements for launch and click-to-focus latency.
2. Expand regression tests for session reuse and focus restoration under rapid switching.
3. Finalize and document terminal surface memory policy (LRU cap or explicit no-cap rationale).

This keeps the current feature set robust before moving into the VZ/Tahoe M2+ track.
