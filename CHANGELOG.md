# Changelog

## [0.1.0] - 2026-02-17

### Added
- refresh icon assets and branding guide
- route shortcuts via policy and harden release workflow
- add dev launcher and sandbox-aware shortcut updates
- polish sidebar UI and add deterministic sidebar capture
- add app icon and branding
- ui: show live terminal indicators for repo sessions
- host: preload ~/code repos and persist repo-click terminal sessions
- m1: pin main terminal to host defaults on launch
- cli: add workspace manager daily-driver commands
- add self-hosted runner support
- extract WorkspaceManager from services monorepo

### Changed
- harden host terminal session presentation flow
- ui: direct session focus and add one-click host navigation
- ui: reduce host session render cost and speed repo preload
- host: harden session lifecycle and window scoping
- value-type protocol boundaries, async process execution, repo setup

### Fixed
- keep inspector closed when creating workspace
- recenter and increase app icon frame occupancy
- apply app icon in dev and bundle builds
- make release cleanup compatible with bash 3
- tolerate missing default keychain in release workflow
- release: harden secret setup and align runner behavior
- terminal: switch main view to selected workspace session
- ui: restore host row and strengthen live session visibility
- harden process execution and workspace terminal lifecycle
- address review findings and add workspace progress follow-up (#9)
- repair broken markdown table in isolation-strategies.md

### Other
- Harden Ghostty shortcut pass-through and add smoke verification
- Unify shortcut routing and harden debug launch against stale app
- clarify and refactor build-ghosttykit
- fix terminal split shortcut and document verification loop
- Rename production heading to Next
- Update release workflow to manual
- Add perf CI validation and archive legacy UI scripts
- Streamline UI test scripts and add shared smoke/capture entrypoints
- Add performance instrumentation, benchmarks, and dashboard docs
- Document release and plan refinments
- sidebar: make repositories header clickable for host terminal
- sidebar: make live-session indicators explicit
- Adopt GhosttyKit terminal stack (#10)

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-02-16

### Added
- Repository-first sidebar hierarchy with nested workspace rows under each repository.
- Collapsible repository rows with compact workspace-count badge indicators.
- Shortcut routing architecture doc: `docs/development/shortcut-routing.md`.

### Changed
- Shortcut handling now follows a Ghostty-first policy by default; app chrome owns only explicit non-overlapping shortcuts (currently `Cmd+B` for sidebar toggle).
- Embedded terminal key-equivalent handling now uses Ghostty binding detection/replay flow instead of one-off per-shortcut interception.
- `launch-dev.sh` now verifies the running executable path to prevent stale-build confusion.
- Product/user-story docs now explicitly define wrapper-vs-terminal shortcut ownership and future routing override direction.

### Fixed
- `Cmd+D` split creation now routes through Ghostty runtime actions into app split state reliably.
- `goto_split` runtime actions are now handled for the current two-pane horizontal split model.
- Release workflow now enforces main-lineage release commits and supports tag-driven releases (`workspaces-v*`).
- Release signing/notarization flow no longer depends on writing signing credentials into repo files during CI.
- Release cleanup now restores prior keychain state safely on self-hosted runners and is compatible with macOS bash 3.

## [0.1.0-alpha.1] - 2026-02-09

### Changed
- Terminal now runs on GhosttyKit (`libghostty`) for faster rendering and better input/focus reliability.
- Workspace terminal behavior remains the same (open per workspace, restart, and focus restore).
- Release/CI flow now builds GhosttyKit automatically before app build/tests.

### Architecture
- Replaced SwiftTerm with a thin Ghostty surface/app-manager integration layer; custom terminal theming is deferred for now.
