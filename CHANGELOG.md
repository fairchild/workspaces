# Changelog

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
