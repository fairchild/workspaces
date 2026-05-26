---
status: done
category: followup
issue: 84
issue_closed: 2026-03-13
milestone: 1
completed_prs: [379, 383]
---

# Ghostty Appearance Sync Hardening

## Problem Statement

Ghostty system appearance sync shipped in PR #14 and is now in mainline. Since then, PR #18 and PR #19 introduced additional hardening around open-in-editor shortcut flow, metrics, and broader terminal-mode behavior. The appearance sync remains relevant and active, but we now need a focused hardening pass to ensure it remains deterministic when combined with new routing and mode semantics.

This focused hardening slice is complete for the currently shipped behavior. The remaining P0 #2 work now lives in the broader main-window/sidebar/Ghostty boundary maintainability track, not in this appearance-specific follow-up.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Backlog category | `followup` | This is post-merge quality hardening, not new product surface area. |
| Scope | Validate + harden interactions, not redesign appearance sync | The implementation in `/Sources/WorkspaceManager/Terminal` is already small and correct. |
| Roadmap placement | Completed P0 #2 sub-track | PR #379 covered split-routing mode behavior, and PR #383 covered appearance dedupe behavior plus docs parity. |
| Risk control | Add explicit tests/smoke coverage for mode + shortcut interactions | Existing tests cover mapping, but not enough integration interaction points. |

## Architecture

```text
macOS appearance changes
  -> GhosttySurfaceView.viewDidChangeEffectiveAppearance()
     -> applySystemColorSchemeIfNeeded()
        -> ghostty_surface_set_color_scheme(surface, scheme)
        -> GhosttyAppManager.applyColorScheme(scheme)
           -> ghostty_app_set_color_scheme(app, scheme)

Recent hardening overlays:
  OpenInEditorShortcutFlow.syncRouting(target)
  TerminalMultiplexingMode (ghostty_managed_splits | tmux_per_session)
```

## What We Learned

- PR #18 and PR #19 do not remove or replace appearance sync logic.
- Appearance sync codepaths remain intact:
  - `Sources/WorkspaceManager/Terminal/GhosttyAppearanceSync.swift`
  - `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
  - `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
- `ContentView` now gates split-action handling by multiplexing mode:
  - `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:726`
- Open-in-editor shortcut routing is now centralized and dynamic:
  - `Sources/WorkspaceManager/Views/MainWindow/OpenInEditorShortcutFlow.swift`
  - `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:707`
- Existing appearance mapping tests still pass:
  - `Tests/WorkspaceManagerAppTests/GhosttyAppearanceSyncTests.swift`
- PR #379 added direct split-routing coverage for the terminal-mode overlay:
  - `Tests/WorkspaceManagerAppTests/SplitRoutingControllerTests.swift`
  - covered `new_split`, `goto_split`, `resize_split`, `equalize_splits`, tmux-mode rejection, and invalid payload rejection
- PR #383 added deterministic appearance coverage for first application, duplicate skipping, forced refresh, and scheme-change decisions.
- Current smoke docs and scripts already state the required `Terminal Multiplexing Mode = Ghostty Splits` precondition and the tmux-mode early-exit behavior:
  - `scripts/shortcut-pass-through-smoke.sh`
  - `scripts/README.md`
  - `docs/development/libghostty-integration.md`
  - `docs/development/shortcut-routing.md`

## Implementation Phases

### Phase 1: Roadmap Positioning + Docs Parity

**Files to modify:**
- `backlog/ROADMAP.md` - Add an explicit line item for appearance-sync interaction hardening in active refinement work.
- `docs/development/libghostty-integration.md` - Document color-scheme sync behavior and expected verification.
- `docs/development/shortcut-routing.md` - Clarify open-in-editor override interplay and multiplexing-mode implications for terminal verification.

**Acceptance criteria:**
- [x] Roadmap explicitly positions this follow-up among recent hardening items.
- [x] Terminal docs reflect current behavior and verification commands.
- [x] Shortcut docs match current app-owned and dynamic override behavior.

### Phase 2: Interaction Test Coverage

**Files to modify:**
- `Tests/WorkspaceManagerAppTests/GhosttyAppearanceSyncTests.swift` - Keep mapper tests; add edge-case expectation coverage if needed.
- `Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift` - Add assertions to protect open-in-editor route behavior while appearance sync is active.
- `Tests/WorkspaceManagerAppTests/HostTerminalStateStoreTests.swift` - Add/adjust assertions ensuring split-mode paths remain deterministic with current mode gating.

**Files to create:**
- `Tests/WorkspaceManagerAppTests/GhosttyAppearanceIntegrationTests.swift` - Integration-focused test coverage for surface/app scheme application decisions (dedupe semantics).

Status:
- Split-routing controller coverage shipped in PR #379.
- Appearance mapper and dedupe coverage now protects first-application, duplicate-skip, forced-refresh, and scheme-change decisions without UI automation.
- Remaining test work should stay focused on shortcut override interplay if new behavior is added.

**Acceptance criteria:**
- [x] New tests fail when scheme application or route interactions regress.
- [x] Existing shortcut and terminal-state suites remain green.
- [x] No brittle test dependence on interactive UI automation.

### Phase 3: Smoke + Verification Hardening

**Files to modify:**
- `scripts/shortcut-pass-through-smoke.sh` - Add explicit precondition/assertion for current multiplexing mode before split checks.
- `scripts/README.md` - Document smoke semantics and expected logs when mode is tmux vs ghostty-managed.

**Acceptance criteria:**
- [x] Smoke script outputs actionable failure reason if mode preconditions are not met.
- [x] Verification guidance includes appearance-related checks in the standard loop.
- [x] Shared-desktop runbook remains usable without forcing app activation.

Status:
- Satisfied by the current script/docs state on `main`. No new activation-driving smoke run was required for this docs reconciliation; running `shortcut-pass-through-smoke.sh` remains an explicit foreground-input action.

## Verification Commands

```bash
./scripts/build-ghosttykit.sh
swift build
swift test
swift test --filter GhosttyAppearanceSync
swift test --filter ShortcutRoutingPolicy

./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'
./scripts/shortcut-pass-through-smoke.sh
```

## Rollback Plan

1. Revert documentation-only changes first if behavior is unchanged but wording drifts.
2. If new integration tests prove too brittle, revert only the new test file and keep deterministic unit-level assertions.
3. If smoke-script hardening causes false negatives, roll back script logic while preserving explicit mode documentation.
4. Keep core appearance-sync runtime code unchanged unless a reproducible regression is confirmed.

## Roadmap Position

- Completed former P0 #2 sub-track **2b**. See `backlog/ROADMAP.md` Priority Bands for the remaining active 2a work.
- Treat future appearance-specific work as a new regression follow-up only when new shortcut, mode, or Ghostty lifecycle behavior creates a fresh gap.

## References

- PR #14 merge commit: `b965d4a60f600aa4ab1c954d70f110b3332cde7e`
- PR #18 merge commit: `b3cc00da35fbdf648afae062bbc266d65da7959a`
- PR #19 merge commit: `4cd0ceb9dc3080c8c49e23c7dff42da3e9e9eff2`
- `Sources/WorkspaceManager/Terminal/GhosttyAppearanceSync.swift`
- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
- `Sources/WorkspaceManager/Views/MainWindow/OpenInEditorShortcutFlow.swift`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
- `docs/development/libghostty-integration.md`
- `docs/development/shortcut-routing.md`
