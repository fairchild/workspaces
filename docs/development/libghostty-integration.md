# libghostty Integration Guide

This document is the canonical reference for the WorkspaceManager terminal
integration with GhosttyKit (`libghostty`).

## Why This Exists

`libghostty` is powerful but still evolving. The public C API and generated
xcframework behavior can change between commits. This guide captures the exact
integration contract in this repo so future sessions can upgrade safely.

## Current Integration Shape

### Build + pinning

- Build script: `/Users/fairchild/code/workspaces/scripts/build-ghosttykit.sh`
- Output path consumed by SPM: `/Users/fairchild/code/workspaces/Frameworks/GhosttyKit.xcframework`
- Pin source of truth: `GHOSTTY_COMMIT` inside the build script
- Toolchain source of truth: `/Users/fairchild/code/workspaces/.mise.toml` (`zig = "0.15.2"`)

Behavior:
- If `GHOSTTY_DIR` is set, script verifies that checkout is exactly at pinned commit.
- If `GHOSTTY_DIR` is unset, script auto-clones into cache and checks out pinned commit.
- Script supports multiple xcframework output locations because Ghostty build output has shifted across revisions.

### Package wiring

`/Users/fairchild/code/workspaces/Package.swift`:
- Uses `.binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework")`
- App target depends on `GhosttyKit`
- App target links extra libs/frameworks required by Ghostty static archive:
  - `c++`
  - `Carbon`, `CoreText`, `Metal`, `QuartzCore`, `UniformTypeIdentifiers`, `UserNotifications`

## Runtime Architecture

### Files

- App/runtime owner: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
- Terminal view: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- Input mapping helpers: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Terminal/GhosttyInput.swift`
- Surface config builder: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift`
- SwiftUI bridge: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/Components/TerminalView.swift`

### App manager responsibilities

`GhosttyAppManager` is a singleton that owns:
- `ghostty_init(...)`
- `ghostty_config_new/finalize/free`
- `ghostty_app_new/free/tick`
- app-wide focus sync via `ghostty_app_set_focus(...)`

Registered callbacks in `ghostty_runtime_config_s`:
- `wakeup_cb`: schedules `ghostty_app_tick` on main queue
- `action_cb`: currently handles terminal title and pwd updates
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

### Focus model

- Window-level focus coordinator remains
  `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Controllers/TerminalWindowController.swift`
- App active/inactive hooks are wired in
  `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/App/WorkspaceManagerApp.swift`
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

1. Edit `GHOSTTY_COMMIT` in `/Users/fairchild/code/workspaces/scripts/build-ghosttykit.sh`.
2. Rebuild framework:
   `./scripts/build-ghosttykit.sh`
3. Run validation:
   - `mask ci`
   - `swift run WorkspaceManager` and manual terminal smoke checks
4. Manual smoke checklist:
   - terminal appears for selected workspace
   - typing, enter, backspace, arrows
   - option/command combinations
   - copy/paste
   - restart button recreates terminal
   - click away/back restores focus
5. If API changes break compile:
   - patch only the terminal integration files listed above
   - update this guide with concrete API changes

## CI Contract

Both workflows build GhosttyKit before lint/build/test:
- `/Users/fairchild/code/workspaces/.github/workflows/ci.yml`
- `/Users/fairchild/code/workspaces/.github/workflows/ci-fallback.yml`

If CI fails in Ghostty build step, debug `scripts/build-ghosttykit.sh` first.

