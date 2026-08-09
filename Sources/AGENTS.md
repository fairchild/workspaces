# Sources/ - Desktop App Context

Swift/SwiftUI code for the native macOS app. Read alongside root `AGENTS.md` (repo-wide process). `CLAUDE.md` here is a symlink to this file — read one, not both.

## Dev Verification Practice (required)

When changing terminal/keyboard/sidebar behavior, run the canonical self-verification loop in `docs/development/libghostty-integration.md` § "Agent self-verification runbook" — this is the short form:

1. `./scripts/build-ghosttykit.sh` (once / after pin changes), then `swift build`.
2. Launch only the debug binary: `./scripts/launch-dev.sh --no-build` (`--no-activate` on a shared desktop with the user present, `--watch` to keep logs attached); `./scripts/dev-smoke.sh --no-build` is the fastest sanity check. On launch failure, inspect the newest `.dev-data/logs/launch-diagnostics-<timestamp>/` bundle.
3. Confirm you're testing the debug app (`DEV` Dock badge + persistent toolbar badge), not `/Applications`: `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`; kill `/Applications/WorkSpaces.app` if both are running.
4. Verify shortcuts (`Cmd+B` sidebar, `Cmd+D` split) via logs — app logging is `os.Logger` (subsystem `com.cloudcompute.workspaces`), which does **not** land in `.dev-data/logs/` (stdout/stderr only). Start `/usr/bin/log stream --predicate 'subsystem == "com.cloudcompute.workspaces"' --level info --style compact` before triggering; expect `"[GhosttyAppManager] action=new_split direction="`.
5. Capture evidence without forcing activation: `./scripts/capture-window.sh` (capture-only, not input-driving; with `--no-activate`, pause your own input during capture). Reserve activation-driving scripts for when foreground input is acceptable; otherwise use Tart/Lume or a separate macOS user/session.
6. Run `./scripts/desktop-ui-smoke.sh --no-build` (`mise run dev-ui-smoke`) end to end — headless-safe UI lane; gate semantics and milestone details are in the runbook.
7. `mise` shortcuts: `dev-launch`, `dev-watch`, `dev-smoke`, `dev-ui-smoke`, plus the `dev-lume-*` family.

**Lume.** Run `mise run dev-lume-ensure` before any Lume work (idempotent, self-healing). Daemon requirements, storage contract, validation lanes, unattended overrides, and the app smoke's automation mode are canonical in `docs/development/lume-integration.md`, `lume-validation.md`, `lume-recreate-runbook.md`, `lume-runner-setup.md`.

Shortcut/split routing: `docs/development/shortcut-routing.md`. Shared-desktop isolation: `backlog/done/shared-desktop-focus-contention-followup.md`.

## Key Patterns

1. **URL Storage**: SwiftData can't store URLs directly. Store as String, access via computed property:
   ```swift
   var path: String  // stored
   var workspaceURL: URL { URL(fileURLWithPath: path) }  // computed
   ```

2. **Protocol-based DI**: Services define protocols in `Protocols.swift`, actors conform. Views receive services via SwiftUI `@Environment`. See `WorkspaceManagerApp.swift` for the `EnvironmentKey` wiring.

3. **Actor Services**: `GitService` and `WorkspaceService` are actors. Inject via protocol (`GitServiceProtocol`, `WorkspaceServiceProtocol`) for testability.

4. **Terminal Recreation**: Use `.id(workspace.id)` to force terminal recreation when workspace changes.

5. **Keyboard Focus**: Ghostty-style retry-based focus restoration. See `docs/development/solution-terminal-keyboard.md`.

6. **App Activation Policy**: All `NSApp.activate` calls — launch and runtime — route through `AppActivationPolicy` (`Sources/WorkspaceManager/App/AppActivationPolicy.swift`). Normal launch: full foreground. `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`: dock visible, no focus steal ever (launch *or* runtime — the env var name is historical). `CI=true`: fully invisible accessory app. Any script that launches the app headlessly should set `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`.

## UI Design Lessons

- **Keep terminal surfaces nearly chrome-free.** Repo overview pages can carry metadata and actions, but terminal views default to the canvas with minimal surrounding UI.
- **Prefer quiet discoverability over persistent controls.** Avoid right-click-only primary actions, but also avoid always-visible sidebar affordances that add noise. Hover-visible scoped actions are usually the right compromise.
- **Persist selection state by stable IDs, not live SwiftData objects.** Resolve models late and validate them against current data before selection.

## Local State Schema

The local SQLite sidecar schema lives in `docs/schema.sql` (implementation plan: `docs/development/local-state-store-plan.md`). Keep the schema doc manually in sync with `LocalStateStore` migrations whenever tables, indexes, or persisted meanings change.

## Don't

- Don't put service logic in Views — use Services/
- Don't store URLs directly in SwiftData models (see Key Patterns #1)
