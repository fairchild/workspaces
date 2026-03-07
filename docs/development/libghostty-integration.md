# libghostty Integration Guide

This document is the canonical reference for the WorkspaceManager terminal
integration with GhosttyKit (`libghostty`).

## Why This Exists

`libghostty` is powerful but still evolving. The public C API and generated
xcframework behavior can change between commits. This guide captures the exact
integration contract in this repo so future sessions can upgrade safely.

## Current Integration Shape

### Build + pinning

- Build script: `scripts/build-ghosttykit.sh`
- Output path consumed by SPM: `Frameworks/GhosttyKit.xcframework`
- Pin source of truth: `GHOSTTY_COMMIT` inside the build script
- Toolchain source of truth: `.mise.toml` (`zig = "0.15.2"`)

Behavior:
- If `GHOSTTY_DIR` is set, script verifies that checkout is exactly at pinned commit.
- If `GHOSTTY_DIR` is unset, script auto-clones into cache and checks out pinned commit.
- Script supports multiple xcframework output locations because Ghostty build output has shifted across revisions.

### Package wiring

`Package.swift`:
- Uses `.binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework")`
- App target depends on `GhosttyKit`
- App target links extra libs/frameworks required by Ghostty static archive:
  - `c++`
  - `Carbon`, `CoreText`, `Metal`, `QuartzCore`, `UniformTypeIdentifiers`, `UserNotifications`

## Runtime Architecture

### Files

- App/runtime owner: `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
- Terminal view: `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- Input mapping helpers: `Sources/WorkspaceManager/Terminal/GhosttyInput.swift`
- Surface config builder: `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift`
- SwiftUI bridge: `Sources/WorkspaceManager/Views/Components/TerminalView.swift`

### App manager responsibilities

`GhosttyAppManager` is a singleton that owns:
- `ghostty_init(...)`
- `ghostty_config_new/finalize/free`
- `ghostty_app_new/free/tick`
- app-wide focus sync via `ghostty_app_set_focus(...)`

Registered callbacks in `ghostty_runtime_config_s`:
- `wakeup_cb`: schedules `ghostty_app_tick` on main queue
- `action_cb`: handles terminal title/pwd updates and forwards split requests to SwiftUI state
- `read_clipboard_cb` / `write_clipboard_cb`
- `confirm_read_clipboard_cb`
- `close_surface_cb`

### Surface view responsibilities

`GhosttySurfaceView` owns one `ghostty_surface_t` and:
- builds `ghostty_surface_config_s` with platform/tag/userdata
- sets working directory, command, environment, font size (surface-level config only)
- maps AppKit keyboard/mouse/scroll/focus events to `ghostty_surface_*` C APIs
- maintains NSTextInputClient path for IME/dead key compatibility
- updates content scale + framebuffer size on backing/frame changes
- installs minimal local monitor for `.leftMouseDown` and command `.keyUp`

### Shortcut + split contract (required behavior)

This project depends on the following keyboard behavior:

- `Cmd+B`: toggles the left sidebar visibility.
- `Cmd+Shift+T`: triggers the app-level new workspace action.
- `Cmd+D`: when a terminal surface is focused, creates a split to the right.

The `Cmd+D` path is runtime-action-driven:

1. `GhosttySurfaceView` routes non-app-owned shortcuts to Ghostty binding handling.
2. `libghostty` dispatches `GHOSTTY_ACTION_NEW_SPLIT` through `ghostty_runtime_action_cb`.
3. `GhosttyAppManager.action(...)` posts a split action notification and returns `true`.
4. The app then materializes the split in UI state (`SplitRoutingController` / `HostTerminalStateStore`).

Important: returning `false` for `GHOSTTY_ACTION_NEW_SPLIT` means "not performed" and
no split will appear even if the key event reached Ghostty.

`performKeyEquivalent` integration rule:
- For key-equivalent checks, call `ghostty_surface_key_is_binding(...)` with event text populated (`keyEvent.text`).
- Preserve AppKit replay semantics (`performKeyEquivalent` + `doCommand`) so command/control shortcuts that don't map to app menus can still flow to Ghostty encoding paths.
- Apply app-vs-terminal ownership via policy (`ShortcutRoutingPolicy`) rather than per-shortcut conditionals.

Current split parity:
- `GHOSTTY_ACTION_NEW_SPLIT` is routed.
- `GHOSTTY_ACTION_GOTO_SPLIT` is routed for the current two-pane split model.
- `GHOSTTY_ACTION_RESIZE_SPLIT` updates the divider when the requested direction matches the active split axis and divider edge.
- `GHOSTTY_ACTION_EQUALIZE_SPLITS` resets the divider to 50/50.
- Orthogonal or unsupported resize directions remain explicit no-ops with logging.

See `docs/development/shortcut-routing.md` for the full routing model.

### Focus model

- Window-level focus coordinator remains
  `Sources/WorkspaceManager/Controllers/TerminalWindowController.swift`
- App active/inactive hooks are wired in
  `Sources/WorkspaceManager/App/WorkspaceManagerApp.swift`
- Retry loop currently starts at 50ms, doubles, caps at 500ms.

## Configuration Scope (intentional constraints)

Current migration uses surface/runtime config only:
- `working_directory`
- `command`
- `env_vars`
- `font_size`

Not configured yet (by design in this migration):
- app-owned color palette / theme overrides
- app-owned font-family override

Reason: keep integration on stable C fields and avoid config file management in v1.

## Known Warnings / Quirks

### Ghostty umbrella-header warnings

During build, Clang may report missing subheaders from GhosttyKit umbrella header.
These are currently non-fatal in our build path.

### Link warnings about ImGui symbols

Link step may warn about missing `_ImFontConfig_ImFontConfig` /
`_ImGuiStyle_ImGuiStyle`. Current app build still succeeds.

Treat both as watch items for future Ghostty pin updates.

## Upgrade Procedure (when bumping Ghostty)

1. Edit `GHOSTTY_COMMIT` in `scripts/build-ghosttykit.sh`.
2. Rebuild framework:
   `./scripts/build-ghosttykit.sh`
3. Run validation:
   - `mask ci`
   - `swift run WorkspaceManager` and manual terminal smoke checks
4. Manual smoke checklist:
   - terminal appears for selected workspace
   - typing, enter, backspace, arrows
   - option/command combinations
   - `Cmd+B` toggles sidebar
   - `Cmd+D` creates visible right split
   - optional: configured Ghostty resize/equalize bindings move the divider and reset it to 50/50
   - copy/paste
   - restart button recreates terminal
   - click away/back restores focus
5. If API changes break compile:
   - patch only the terminal integration files listed above
   - update this guide with concrete API changes

## CI Contract

Both workflows build GhosttyKit before lint/build/test:
- `.github/workflows/ci.yml`
- `.github/workflows/ci-fallback.yml`

If CI fails in Ghostty build step, debug `scripts/build-ghosttykit.sh` first.

## Agent self-verification runbook

Use this exact loop in future sessions to avoid stale-build confusion:

1. Rebuild pinned GhosttyKit:
   - `./scripts/build-ghosttykit.sh`
2. Build app:
   - `swift build`
3. Launch debug app (never `/Applications` during verification):
   - `./scripts/launch-dev.sh --no-build`
   - shared-desktop option: `./scripts/launch-dev.sh --no-build --no-activate`
4. Verify process path points to `.build/.../WorkspaceManager`:
   - `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`
5. Exercise shortcuts:
   - `Cmd+B` collapse/restore sidebar
   - `Cmd+D` create split pane
   - optional: trigger configured resize/equalize bindings and confirm divider movement / 50:50 reset
   - Optional scripted smoke: `mask verify-shortcuts`
6. Verify split runtime path in logs:
   - `tail -n 80 .dev-data/logs/launch-dev-*.log`
   - Expect `"[GhosttyAppManager] action=new_split direction="`
   - Optional resize/equalize traces:
     - `"[GhosttyAppManager] action=resize_split direction="`
     - `"[GhosttyAppManager] action=equalize_splits"`

If shortcut behavior regresses, first confirm step 4 before changing code.
