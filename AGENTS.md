# WorkspaceManager Agent Notes

## Dev Verification Practice (required)

When changing terminal/keyboard/sidebar behavior, use this loop so future sessions can self-verify reliably:

1. Build pinned GhosttyKit and app:
   - `./scripts/build-ghosttykit.sh`
   - `swift build`
2. Launch only the debug binary:
   - `./scripts/launch-dev.sh --no-build`
3. Confirm the running process is the debug path (not `/Applications`):
   - `ps aux | rg '/Users/fairchild/code/workspaces/.build/arm64-apple-macosx/debug/WorkspaceManager'`
4. Verify shortcut behavior:
   - `Cmd+B` toggles left sidebar
   - `Cmd+D` creates a visible right split for the focused terminal
5. If split fails, check launch logs in `.dev-data/logs/` for:
   - `"[GhosttyAppManager] action=new_split direction="`

Canonical reference:
- `/Users/fairchild/code/workspaces/docs/development/libghostty-integration.md` ("Shortcut + split contract" and "Agent self-verification runbook")
- `/Users/fairchild/code/workspaces/docs/development/shortcut-routing.md` ("Shortcut Routing Architecture")

## Commit Hygiene

- Do not include screenshot artifacts in commits unless explicitly requested (`/Users/fairchild/code/workspaces/output/`).
