# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0-alpha.1] - 2026-02-09

### Added
- Migrated embedded terminal from SwiftTerm to GhosttyKit (`libghostty`).
- Added Ghostty bootstrap script at `scripts/build-ghosttykit.sh` with pinned commit and auto-clone fallback.
- Added terminal runtime layer:
  - `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
  - `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
  - `Sources/WorkspaceManager/Terminal/GhosttyInput.swift`
  - `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift`
- Added libghostty integration runbook:
  - `docs/development/libghostty-integration.md`

### Changed
- Updated app target dependencies in `Package.swift` to use `GhosttyKit` binary target.
- Updated CI workflows to build GhosttyKit before lint/build/test.
- Reworked terminal focus and lifecycle wiring in:
  - `Sources/WorkspaceManager/Controllers/TerminalWindowController.swift`
  - `Sources/WorkspaceManager/App/WorkspaceManagerApp.swift`
- Updated docs to reflect Ghostty terminal architecture and troubleshooting flow.

### Removed
- Removed SwiftTerm-specific terminal files:
  - `Sources/WorkspaceManager/Views/Components/TerminalNSContainerView.swift`
  - `Sources/WorkspaceManager/Views/Components/TerminalTheme.swift`

