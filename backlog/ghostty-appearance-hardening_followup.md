---
status: pending
category: followup
issue: 84
milestone: 1
---

# Ghostty Appearance Sync Hardening

## Problem Statement

Ghostty system appearance sync shipped in PR #14 and is now in mainline. Since then, PR #18 and PR #19 introduced additional hardening around open-in-editor shortcut flow, metrics, and broader terminal-mode behavior. The appearance sync remains relevant and active, but we now need a focused hardening pass to ensure it remains deterministic when combined with new routing and mode semantics.

This work is deferred because the merged behavior is functionally correct today and current active priority is the maintainability-first quality pass in the main window/sidebar/Ghostty surfaces. The risk is not immediate feature breakage; it is regression risk as terminal routing continues to evolve.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Backlog category | `followup` | This is post-merge quality hardening, not new product surface area. |
| Scope | Validate + harden interactions, not redesign appearance sync | The implementation in `/Sources/WorkspaceManager/Terminal` is already small and correct. |
| Roadmap placement | Sequence as a small Ghostty-quality follow-up within or just after the current maintainability milestone | It directly depends on recent routing/mode changes and should ride the same quality-first execution wave. |
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

## Implementation Phases

### Phase 1: Roadmap Positioning + Docs Parity

**Files to modify:**
- `backlog/ROADMAP.md` - Add an explicit line item for appearance-sync interaction hardening in active refinement work.
- `docs/development/libghostty-integration.md` - Document color-scheme sync behavior and expected verification.
- `docs/development/shortcut-routing.md` - Clarify open-in-editor override interplay and multiplexing-mode implications for terminal verification.

**Acceptance criteria:**
- [ ] Roadmap explicitly positions this follow-up among recent hardening items.
- [ ] Terminal docs reflect current behavior and verification commands.
- [ ] Shortcut docs match current app-owned and dynamic override behavior.

### Phase 2: Interaction Test Coverage

**Files to modify:**
- `Tests/WorkspaceManagerAppTests/GhosttyAppearanceSyncTests.swift` - Keep mapper tests; add edge-case expectation coverage if needed.
- `Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift` - Add assertions to protect open-in-editor route behavior while appearance sync is active.
- `Tests/WorkspaceManagerAppTests/HostTerminalStateStoreTests.swift` - Add/adjust assertions ensuring split-mode paths remain deterministic with current mode gating.

**Files to create:**
- `Tests/WorkspaceManagerAppTests/GhosttyAppearanceIntegrationTests.swift` - Integration-focused test coverage for surface/app scheme application decisions (dedupe semantics).

Status:
- Split-routing controller coverage shipped in PR #379. Remaining test work should stay focused on appearance-specific dedupe/application behavior and shortcut override interplay.

**Acceptance criteria:**
- [ ] New tests fail when scheme application or route interactions regress.
- [ ] Existing shortcut and terminal-state suites remain green.
- [ ] No brittle test dependence on interactive UI automation.

### Phase 3: Smoke + Verification Hardening

**Files to modify:**
- `scripts/shortcut-pass-through-smoke.sh` - Add explicit precondition/assertion for current multiplexing mode before split checks.
- `scripts/README.md` - Document smoke semantics and expected logs when mode is tmux vs ghostty-managed.

**Acceptance criteria:**
- [ ] Smoke script outputs actionable failure reason if mode preconditions are not met.
- [ ] Verification guidance includes appearance-related checks in the standard loop.
- [ ] Shared-desktop runbook remains usable without forcing app activation.

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

- Sits in P0 #2 as sub-track **2b** (narrow), alongside the structural main-window/sidebar maintainability work in 2a. See `backlog/ROADMAP.md` Priority Bands for the current pairing.
- Either sub-track can move independently. This one is the smaller, lower-risk option — pick it when 2a is too large for the session shape.
- Treat as a risk-reduction task, not a feature track.

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
