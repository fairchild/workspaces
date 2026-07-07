# libghostty Integration Guide

This document is the canonical reference for the WorkspaceManager terminal
integration with GhosttyKit (`libghostty`).

## Why This Exists

`libghostty` is powerful but still evolving. The public C API and generated
xcframework behavior can change between commits. This guide captures the exact
integration contract in this repo so future sessions can upgrade safely.

The local [Automation API Reference](./automation-api.md) builds on the same
terminal session and surface identity model. When changing split or focus
behavior here, keep the automation API's context, surface list, focus, and split
semantics aligned.

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
- Runtime action bridge: `Sources/WorkspaceManager/Terminal/GhosttyRuntimeActionBridge.swift`
- Terminal view: `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- Input routing helper: `Sources/WorkspaceManager/Terminal/GhosttySurfaceInputRouter.swift`
- IME/text-input helper: `Sources/WorkspaceManager/Terminal/GhosttySurfaceTextInputBridge.swift`
- Input mapping helpers: `Sources/WorkspaceManager/Terminal/GhosttyInput.swift`
- Surface config builder: `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift`
- SwiftUI bridge: `Sources/WorkspaceManager/Views/Components/TerminalView.swift`

### App manager responsibilities

`GhosttyAppManager` is a singleton that owns:
- `ghostty_init(...)`
- `ghostty_config_new/finalize/free`
- `ghostty_app_new/free/tick`
- app-wide focus sync via `ghostty_app_set_focus(...)`
- clipboard callbacks + app-level color-scheme synchronization
- the live Terminal Theme apply (`applyTheme(lightTheme:darkTheme:)`) and a weak
  registry of live `GhosttySurfaceView`s to broadcast it to (see "Terminal Theme")

Registered callbacks in `ghostty_runtime_config_s`:
- `wakeup_cb`: schedules `ghostty_app_tick` on main queue
- `action_cb`: delegates runtime action decoding and split notification posting to `GhosttyRuntimeActionBridge`
- `read_clipboard_cb` / `write_clipboard_cb`
- `confirm_read_clipboard_cb`
- `close_surface_cb`

### Surface view responsibilities

`GhosttySurfaceView` owns one `ghostty_surface_t` and:
- builds `ghostty_surface_config_s` with platform/tag/userdata
- sets working directory, command, environment, font size (surface-level config only)
- keeps lifecycle/appearance work localized to surface creation, sizing, and per-surface color updates
- delegates keyboard/mouse/shortcut routing to `GhosttySurfaceInputRouter`
- delegates NSTextInputClient / IME / dead-key behavior to `GhosttySurfaceTextInputBridge`
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
3. `GhosttyRuntimeActionBridge` posts a split action notification and returns `true` through `GhosttyAppManager.action(...)`.
4. The app then materializes the split in UI state (`SplitRoutingController` / `TileTreeStore`).

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

Current split verification expectation:
- `shortcut-pass-through-smoke.sh` is valid only when `Terminal Multiplexing Mode = Ghostty Splits`.
- If the app is in `tmux` mode, Ghostty split actions are intentionally not expected to materialize in Workspaces UI, and the script exits early with guidance.

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

`TerminalSessionLaunchContext` decides the command mode and hook environment
before `GhosttyTerminalConfig` translates that policy into the libghostty surface
fields above.

Not configured yet (by design in this migration):
- app-owned font-family override

App-owned config-file keys:
- `theme = light:<L>,dark:<D>` when Terminal Theme is selected
- `scrollbar = system`
- `mouse-scroll-multiplier = precision:0.7,discrete:1`

Reason: keep integration on stable C fields and a small isolated config file
instead of loading the user's `~/.config/ghostty`.

## Terminal Theme (app-owned config + live update)

WorkSpaces sets terminal behavior defaults and the optional terminal color theme
through a small, app-owned config file applied live — never via OSC escapes or
surface recreation. See the ADR
`docs/decisions/ghostty-theme-config.md` for the rationale.

Contract:

- **Config file**: `<dataDir>/ghostty/workspaces.config` (the `WORKSPACES_DATA_DIR`
  convention, else the app support dir), isolated from `~/.config/ghostty`, which
  we never load. It contains WorkSpaces-managed keys only: scrollbar visibility,
  scroll speed, and an optional `theme = light:<L>,dark:<D>`.
- **Catalog**: themes are enumerated at runtime from `<resources>/ghostty/themes/`
  via `GhosttyResourcesLocator.resolvedResourcesDirectory()` — each filename *is*
  the `theme =` value. `GhosttyThemeCatalog` exposes `all`, `featured`, and fuzzy
  `rank`. Release bundles the resources; dev builds do not, so the catalog is
  empty unless `GHOSTTY_RESOURCES_DIR` points at a Ghostty share dir.
  `launch-dev.sh` auto-resolves one from the pinned checkout
  (`~/.cache/workspacemanager/ghostty/zig-out/share/ghostty`), so a plain
  `./scripts/launch-dev.sh` shows themes; a direct-binary launch still needs the
  env var set by hand.
- **Startup**: `initializeIfNeeded()` builds the initial `ghostty_config_t` from
  the persisted pair (`GhosttyThemePersistence`, `UserDefaults`). The config file
  is always written for WorkSpaces scroll defaults; with a selected theme it also
  includes `theme = …`. The file is loaded before `ghostty_app_new`, so the first
  surfaces inherit the behavior.
- **Live change**: `applyTheme(lightTheme:darkTheme:)` rewrites the file, rebuilds
  a fresh config, broadcasts via `ghostty_app_update_config(app, cfg)` and
  `ghostty_surface_update_config(surface, cfg)` over the weak surface registry,
  then frees the previous config. Scrollback is preserved; new splits/tabs
  inherit the theme from the updated app config.
- **Dual form is required**: Ghostty rejects a single-sided `theme = light:foo`,
  so an unset slot is filled with `Builtin Light` / `Builtin Dark`; both unset
  writes no theme line while preserving the WorkSpaces-managed non-theme defaults.
- **Preview/commit**: `GhosttyThemeStore` (the observable both the Settings
  pickers and the Cmd+Shift+P overlay bind to) drives debounced previews
  (`preview`/`endPreview`, no persistence) and commits (`setLightTheme` /
  `setDarkTheme`, persisted). The active half follows the macOS appearance via
  the existing `set_color_scheme` path, so a slot only previews live while its
  matching appearance is active.
- **Recents**: committed themes are remembered (`recentThemes`, persisted under
  `terminalThemeRecents`, most-recent-first, capped at 8) and pinned in a
  "Recent" section above Featured. The picker's initial highlight lands on the
  most recent theme, so re-selecting a recent is a single arrow press away.

## Appearance Sync

`GhosttyAppearanceSync` is the single mapping layer for AppKit appearance -> Ghostty color scheme.

- Surface-level updates call `ghostty_surface_set_color_scheme(...)` only when the resolved scheme actually changes, unless the caller explicitly forces a refresh.
- App-level updates call `ghostty_app_set_color_scheme(...)` through the same dedupe helper so the global Ghostty app and the active surface stay in sync without duplicate writes.
- `GhosttyAppearanceSync.nextColorScheme(...)` is the pure test seam for first application, duplicate skipping, forced refresh, and scheme-change decisions.
- Current mapping stays intentionally small: Aqua -> light, Dark Aqua -> dark.

## Known Warnings / Quirks

### Ghostty umbrella-header warnings

During build, Clang may report missing subheaders from GhosttyKit umbrella header.
These are currently non-fatal in our build path.

### Link warnings about ImGui symbols

Link step may warn about missing `_ImFontConfig_ImFontConfig` /
`_ImGuiStyle_ImGuiStyle`. Current app build still succeeds.

Treat both as watch items for future Ghostty pin updates.

### Zig 0.15.2 with newer macOS SDKs

Ghostty `v1.3.1` requires Zig `0.15.2`. The upstream Zig 0.15.2 binary can fail
with Xcode 26.4 while linking its build runner with unresolved libSystem symbols.
Homebrew's `zig@0.15` formula carries the Darwin linker patch needed on Tahoe
hosts, so `scripts/build-ghosttykit.sh` prefers:
- `GHOSTTY_ZIG_BIN`, if set
- `/opt/homebrew/opt/zig@0.15/bin/zig`, if installed
- `mise exec zig@0.15.2` as a fallback

Do not bump Ghostty to Zig `0.16.0` for this release line: Ghostty `v1.3.1`
explicitly rejects that compiler and uses Zig APIs removed in `0.16.0`.

The script passes `-Demit-macos-app=false` because Workspaces only needs
`GhosttyKit.xcframework`; building Ghostty's full app bundle adds an unrelated
`xcodebuild` step that can fail after the xcframework has already been produced.

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
   - fastest startup sanity check: `./scripts/dev-smoke.sh --no-build`
   - keep logs attached while debugging launcher/startup issues: `./scripts/launch-dev.sh --no-build --watch`
   - direct binary fallback if the launcher itself is being debugged:
     `WORKSPACES_DATA_DIR=.dev-data/workspacemanager WORKSPACES_APP_VARIANT=dev .build/arm64-apple-macosx/debug/WorkspaceManager`
4. Verify process path points to `.build/.../WorkspaceManager`:
   - `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`
   - debug launches set `WORKSPACES_APP_VARIANT=dev`; the debug app shows a `DEV` Dock badge and a `Development Build` window subtitle
   - if both the debug and installed apps are running, kill `/Applications/WorkSpaces.app` before testing
5. Shared-desktop-safe capture handshake:
   - if you launched with `--no-activate`, pause your own keyboard/mouse input
   - run `./scripts/capture-window.sh`
   - resume input after the capture finishes
6. Exercise shortcuts when activation is allowed:
   - `Cmd+B` collapse/restore sidebar
   - `Cmd+D` create split pane
   - optional: trigger configured resize/equalize bindings and confirm divider movement / 50:50 reset
   - `./scripts/shortcut-pass-through-smoke.sh` is intentionally not shared-desktop-safe and requires `Ghostty Splits` mode
   - Optional scripted smoke: `mask verify-shortcuts`
7. Verify split runtime path in logs:
   - `tail -n 80 .dev-data/logs/launch-dev-*.log`
   - Expect `"[GhosttyAppManager] action=new_split direction="`
   - Optional resize/equalize traces:
     - `"[GhosttyAppManager] action=resize_split direction="`
     - `"[GhosttyAppManager] action=equalize_splits"`
8. If you need input-driving automation without foreground activation on a shared desktop, escalate to Tart/Lume or a separate macOS user/session instead of forcing local focus.

If shortcut behavior regresses, first confirm step 4 before changing code.
