---
status: pending
category: plan
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# tmux Per-Worktree Support Plan

## Problem Statement

Workspaces is currently optimized for Ghostty-managed splits with app-level host sessions. A tmux-backed mode already exists at command bootstrap level, but it is not yet a full product path with clear mode transitions, shortcut documentation, and operational guardrails.

The intended model is one embedded terminal surface per repo/workspace session, with tmux handling all pane/window multiplexing inside that terminal. This keeps Workspaces focused on portfolio/worktree management while deferring terminal multiplexing semantics to tmux.

## Why We Explored This

- Product context emphasizes terminal-first workflows and fast context switching across many repos/workspaces.
- Existing Ghostty split model is currently a two-pane abstraction, while tmux supports deeper, user-controlled multiplexing.
- User demand: keep one Workspaces terminal per worktree and rely on tmux for all sub-session layout/navigation.

## Why Deferred

- Existing implementation is partial: command bootstrap supports tmux mode, but mode-change lifecycle, UX guardrails, and docs/test coverage are incomplete.
- This touches keyboard routing, session lifecycle, and user expectations; execution should follow an explicit phased plan to avoid regressions.

## What We Learned

- `tmux_per_session` mode is already wired into terminal startup command composition.
- Current split action handling is mode-gated (`ghostty_managed_splits` only), but existing split state is not explicitly normalized when switching modes.
- Shortcut documentation is partially stale versus current app-owned commands.
- tmux default bindings (prefix `Ctrl+B`) largely avoid direct collision with current app-owned `Cmd+*` shortcuts.

## Pros, Cons, and Tradeoffs

| Area | tmux Per-Worktree (Target) | Ghostty-Managed Splits (Current Default) | Tradeoff |
|------|-----------------------------|-------------------------------------------|----------|
| Multiplexing depth | Full tmux panes/windows/sessions | App currently models at most one split session per primary | tmux is more powerful but less discoverable for non-tmux users |
| Portability of habits | Matches tmux users across terminals/SSH | Ghostty-native shortcuts in app window | tmux lowers app ownership but increases reliance on external tool conventions |
| App complexity | Simpler split UI/state in app when tmux mode active | App owns split creation/focus logic | tmux mode reduces split-state complexity if we fully collapse app splits |
| Shortcut ergonomics | Prefix-driven (`Ctrl+B`, then command key) | Direct `Cmd+D`, `Cmd+[`, `Cmd+]` Ghostty bindings | tmux avoids `Cmd+` conflicts but requires prefix mental model |
| Dependency surface | Requires tmux installed and reachable in PATH | No extra dependency | requires availability checks, fallback messaging, onboarding copy |
| Failure modes | tmux socket/session issues possible | Ghostty callback/split routing issues possible | tmux mode shifts risk from app split state to external process/tooling |

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Multiplexing architecture | Keep dual modes: `ghostty_managed_splits` and `tmux_per_session` | Preserves current behavior while offering advanced tmux path |
| Session granularity | One deterministic tmux session per normalized worktree path | Matches "one terminal per worktree", stable attach-or-create |
| tmux namespace | Continue dedicated server socket via `-L workspaces` | Isolates Workspaces-managed sessions from user default tmux server |
| Mode-switch semantics | Treat mode switch as terminal lifecycle event (restart + split normalization) | Avoid mixed stale surfaces where command mode and UI mode diverge |
| App split behavior in tmux mode | App split tree must be collapsed/disabled | Prevent dual attached clients to same tmux session inside app chrome |
| Shortcut ownership | Keep app-owned `Cmd+*` shortcuts constant; let tmux handle `Ctrl+B` flows | Minimizes collisions and preserves app chrome controls |
| Availability UX | Explicitly surface tmux availability and fallback behavior in settings | Avoid silent fallback confusion |
| Verification | Add tmux-mode smoke path and explicit acceptance checks | Reduces risk of regressions hidden behind settings toggle |

## Architecture

```text
Settings (Terminal Mode Picker)
          |
          v
TerminalMultiplexingMode (AppStorage)
          |
          v
Mode Transition Coordinator
  - restart active surfaces
  - collapse app split state when tmux mode
          |
          v
GhosttyTerminalConfig
  - ghostty mode: <shell> --login
  - tmux mode:    <shell> --login -c 'exec tmux -L workspaces new-session -A -s <deterministic> -c <cwd>'
          |
          v
Embedded terminal surface (one per worktree session)
          |
          v
tmux manages pane/window multiplexing internally
```

## Shortcut Comparison and Overlap (Research Artifact)

### Current app-owned shortcuts in Workspaces

Source: `Sources/WorkspaceManager/App/AppChromeShortcuts.swift`.

| Shortcut | Owner | Behavior |
|----------|-------|----------|
| `Cmd+B` | App | Toggle sidebar |
| `Cmd+Shift+B` | App | Toggle inspector |
| `Cmd+J` | App | Toggle terminal panel |
| `Cmd+Shift+T` | App | New workspace |
| `Cmd+Shift+O` | App (context/override-aware) | Open in editor |

### Ghostty split/navigation shortcuts used by current app flow

Sources:
- `docs/development/libghostty-integration.md`
- `Sources/WorkspaceManager/App/TerminalMultiplexingMode.swift`

| Shortcut | Expected behavior in Ghostty mode |
|----------|------------------------------------|
| `Cmd+D` | New split |
| `Cmd+[` | Focus previous split |
| `Cmd+]` | Focus next split |

### tmux default key bindings (tmux 3.6a)

Source command: `MANWIDTH=140 man tmux | col -bx` (DEFAULT KEY BINDINGS section).

| Sequence | tmux default behavior |
|----------|------------------------|
| `Ctrl+B` then `"` | Split top/bottom |
| `Ctrl+B` then `%` | Split left/right |
| `Ctrl+B` then arrow keys | Move between panes |
| `Ctrl+B` then `o` | Next pane |
| `Ctrl+B` then `c` | New window |
| `Ctrl+B` then `n` / `p` | Next/previous window |
| `Ctrl+B` then `[` | Enter copy mode |
| `Ctrl+B` then `d` | Detach client |

### Overlap summary

- Direct chord collisions are minimal because Workspaces app shortcuts are `Cmd+*` while tmux defaults are `Ctrl+B` prefix sequences.
- Main risk is user confusion when Ghostty split shortcuts are muscle memory (`Cmd+D`, `Cmd+[`, `Cmd+]`) but tmux mode expects prefix flows.
- Plan outcome: make mode behavior explicit in UI/docs and ensure mode transitions cleanly disable app split state.

## Current Code Findings (Research Artifact)

- tmux mode enum and settings storage exist: `Sources/WorkspaceManager/App/TerminalMultiplexingMode.swift:8`
- Settings picker already exposes both modes: `Sources/WorkspaceManager/Views/SettingsView.swift:115`
- tmux command bootstrap already exists: `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift:50`
- Ghostty split actions are ignored outside Ghostty mode: `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:725`
- Current app-owned default routing includes four chrome shortcuts: `Sources/WorkspaceManager/App/AppChromeShortcuts.swift:75`
- Shortcut routing doc currently lists only a subset of app-owned defaults: `docs/development/shortcut-routing.md:19`

## Implementation Phases

### Phase 1: Product Contract and Docs Alignment

**Files to modify:**
- `docs/product_overview.md`
  Clarify tmux mode behavior as an alternative terminal multiplexing path and its ownership boundary.
- `docs/user-stories.md`
  Add/extend story coverage for tmux-per-worktree workflow.
- `docs/development/shortcut-routing.md`
  Update app-owned default shortcut list and add tmux-mode routing notes.
- `docs/development/libghostty-integration.md`
  Document mode-specific split behavior (Ghostty mode vs tmux mode).

**Files to create:**
- `docs/development/tmux-mode.md`
  Canonical tmux-mode reference: lifecycle, shortcuts, troubleshooting, and expected behavior.

**Acceptance criteria:**
- [ ] Docs state an explicit mode contract for Ghostty vs tmux behavior.
- [ ] App-owned shortcut list in docs matches code.
- [ ] tmux mode docs include verified default key sequences and expected in-app behavior.

### Phase 2: Mode Transition Lifecycle Hardening

**Files to modify:**
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
  Observe terminal mode changes and trigger deterministic transition flow.
- `Sources/WorkspaceManager/Views/Components/TerminalView.swift`
  Add surface invalidation hooks for mode changes.
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` (HostTerminalStateStore section)
  Add explicit APIs to collapse/clear app split sessions when entering tmux mode.

**Files to create:**
- `Sources/WorkspaceManager/Terminal/TerminalModeTransitionCoordinator.swift`
  Centralize transition actions (restart behavior, split normalization, logging).

**Acceptance criteria:**
- [ ] Switching modes causes active sessions to run in the selected mode without manual app restart.
- [ ] Entering tmux mode removes app-managed split panes for active sessions.
- [ ] No stale Ghostty split UI persists after mode change to tmux.

### Phase 3: tmux Bootstrap and Availability UX

**Files to modify:**
- `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift`
  Extract tmux command composition and availability checks into testable helpers.
- `Sources/WorkspaceManager/Views/SettingsView.swift`
  Show tmux availability status and explicit fallback messaging.
- `Sources/WorkspaceManager/App/TerminalMultiplexingMode.swift`
  Improve mode summaries with concrete shortcut expectations.

**Files to create:**
- `Sources/WorkspaceManager/Terminal/TmuxRuntimeSupport.swift`
  tmux path detection, session-name utilities, diagnostics helpers.

**Acceptance criteria:**
- [ ] Users can see whether tmux is available before enabling tmux mode.
- [ ] Fallback behavior when tmux is missing is explicit and user-visible.
- [ ] tmux session naming remains deterministic and collision-resistant.

### Phase 4: Shortcut and Routing Policy Refinements for Dual Mode

**Files to modify:**
- `Sources/WorkspaceManager/App/ShortcutRoutingPolicy.swift`
  Ensure routing policy remains explicit and mode-aware where needed.
- `Sources/WorkspaceManager/App/AppChromeShortcuts.swift`
  Keep app-owned set minimal and synchronized with docs.
- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
  Add explicit handling comments/guards for mode-specific key flow assumptions.

**Files to create:**
- `Sources/WorkspaceManager/App/ShortcutProfiles.swift`
  Optional mode profiles documenting expected terminal vs app ownership.

**Acceptance criteria:**
- [ ] App-owned shortcuts remain functional in both modes.
- [ ] tmux prefix workflows (`Ctrl+B` sequences) operate without app interception.
- [ ] Mode-specific shortcut behavior is documented and test-covered.

### Phase 5: Test Coverage and Smoke Verification

**Files to modify:**
- `Tests/WorkspaceManagerAppTests/GhosttyTerminalConfigTests.swift`
  Expand tmux tests for mode transitions and fallback surfaces.
- `Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift`
  Add cases for dual-mode routing expectations.
- `Tests/WorkspaceManagerAppTests/HostTerminalStateStoreTests.swift`
  Add split-normalization tests when tmux mode is active.
- `scripts/shortcut-pass-through-smoke.sh`
  Keep Ghostty-mode smoke as-is and make mode explicit.

**Files to create:**
- `scripts/tmux-mode-smoke.sh`
  Verify tmux mode attach-or-create behavior and no app split side effects.

**Acceptance criteria:**
- [ ] Automated tests cover mode switch, split normalization, and tmux bootstrap behavior.
- [ ] Smoke script provides evidence for tmux session attach/reuse and stable shortcuts.
- [ ] Verification runbook supports both Ghostty mode and tmux mode paths.

## Verification Commands

```bash
# Build + tests
cd .
./scripts/build-ghosttykit.sh
swift build
swift test

# Launch debug app (shared-desktop safe)
./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'

# Ghostty mode smoke (existing)
./scripts/shortcut-pass-through-smoke.sh

# tmux mode checks (after implementation)
# 1) Enable "tmux Per Session" in settings
# 2) Select repo/workspace and confirm tmux session attach:
tmux -L workspaces ls

# 3) In terminal, verify tmux session id:
#    tmux display-message -p '#S'
# 4) Confirm Ctrl+B then % / " creates panes in tmux, not app split chrome
```

## Rollback Plan

1. Force default mode to `ghostty_managed_splits` in `Sources/WorkspaceManager/App/TerminalMultiplexingMode.swift`.
2. Remove tmux availability UI from settings and keep mode hidden behind an internal flag.
3. Disable tmux bootstrap path in `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift` (fallback to login shell only).
4. Retain doc notes in changelog/backlog for future reintroduction.
5. Re-run `swift test` and shortcut smoke checks to confirm Ghostty path remains stable.

## References

- `docs/product_overview.md:18`
- `docs/product_overview.md:83`
- `docs/user-stories.md:373`
- `docs/development/libghostty-integration.md:70`
- `docs/development/shortcut-routing.md:17`
- `Sources/WorkspaceManager/App/TerminalMultiplexingMode.swift:8`
- `Sources/WorkspaceManager/Views/SettingsView.swift:115`
- `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift:50`
- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift:333`
- `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift:190`
- `Sources/WorkspaceManager/App/AppChromeShortcuts.swift:11`
- `Sources/WorkspaceManager/App/ShortcutRoutingPolicy.swift:51`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:725`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:1199`
- `Sources/WorkspaceManagerCore/Services/HostTerminalSessionCoordinator.swift:89`
- `man tmux` (tmux 3.6a, DEFAULT KEY BINDINGS section; captured via `MANWIDTH=140 man tmux | col -bx`)
