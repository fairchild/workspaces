---
status: pending
category: plan
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# Repo Webview Mode

## Problem Statement

The app is terminal-first, but repository workflows that include a local web app currently require context switching out of the app to preview results. For repos with a known run command and URL, this creates unnecessary friction when iterating quickly.

We want a repo-level "web" mode that can be toggled from the same selection flow used for terminal sessions. Clicking a repo should continue to open its terminal session, while a dedicated web icon should switch the main content pane to an embedded browser for that repo.

## Why Deferred

- Current request is exploration/design only, not implementation.
- This touches persistence, process lifecycle, and main-detail routing, so it should ship as a scoped feature pass with tests.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Web config scope | Repo-level fields (`run command`, `URL`) | Matches user mental model: each repo owns one dev server entry point. |
| Primary UX | Keep terminal default, add explicit web toggle icon | Preserves terminal-first product direction while enabling quick preview. |
| Where web renders | In the main detail pane (replacing terminal view when active) | Aligns with request: "view that instead of terminal". |
| Process model | Dedicated repo web runtime manager, separate from Ghostty surfaces | Avoids coupling dev-server lifecycle to interactive terminal focus/split behavior. |
| URL safety defaults | Prefer loopback (`localhost`, `127.0.0.1`) with explicit override later | Reduces risk of silently embedding arbitrary remote sites. |
| Scope boundary | Workspace right pane remains workspace-only in v1 | Keeps first implementation focused on repo-level preview path. |

## Architecture

```text
Sidebar Repo Click
   -> existing host-terminal session activation (unchanged)
   -> selected repo inferred from active repo path

Toolbar Web Icon Click
   -> detail mode switches terminal <-> web
   -> if web mode:
      RepoWebRuntimeManager.ensureRunning(repo)
      RepoWebView loads configured URL

Main Detail Pane
   -> Terminal mode: HostTerminalSessionStack (existing)
   -> Web mode: RepoWebContainerView (WKWebView + status chrome)
```

## Current Code Findings

- Repo model has no web config fields yet: `/Users/fairchild/code/workspaces/Sources/WorkspaceManagerCore/Models/Models.swift:13`
- Repo selection and host session activation happen in `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:137`
- Main detail pane is terminal-only today: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:482`
- Repo row currently has one action surface (select terminal) and no secondary icon: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:100`
- Repo context menu has no "web config" entry yet: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:92`

## Implementation Phases

### Phase 1: Persist Repo Web Configuration

**Files to modify:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManagerCore/Models/Models.swift` - add optional repo fields for web command and URL, plus lightweight validation helpers.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift` - add repo context-menu action and sheet wiring for editing web settings.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift` - optional inline web affordance in repo row (globe icon) if desired beyond toolbar-only flow.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/App/WorkspaceManagerApp.swift` - ensure fixture data remains valid with new repo fields.

**Files to create:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/RepoWebConfigSheet.swift` - form UI for command/URL and validation feedback.

**Acceptance criteria:**
- [ ] Repo web command and URL can be saved/edited per repo.
- [ ] Existing repos migrate without data loss and default to `nil` config.
- [ ] Invalid URLs are blocked with clear validation messaging.

### Phase 2: Add Repo Web Runtime Manager

**Files to create:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Web/RepoWebRuntimeManager.swift` - process lifecycle manager keyed by repo identity/path.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Web/RepoWebTypes.swift` - runtime status enum and state models (`stopped`, `starting`, `running`, `failed`).

**Files to modify:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - own runtime manager and route selected repo data to detail pane.
- `/Users/fairchild/code/workspaces/Package.swift` - link WebKit framework for WKWebView host view.

**Acceptance criteria:**
- [ ] Switching to web mode starts run command when needed.
- [ ] Runtime state is visible (starting/running/failed) and recoverable.
- [ ] Terminal sessions remain intact and resumable when returning from web mode.

### Phase 3: Integrate WKWebView Detail Mode

**Files to create:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/Components/RepoWebView.swift` - `NSViewRepresentable` wrapper around `WKWebView`.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/RepoWebContainerView.swift` - web toolbar/status/loading/error shell.

**Files to modify:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - add detail mode enum and toolbar web toggle button.

**Acceptance criteria:**
- [ ] A selected repo with config shows an enabled web icon.
- [ ] Clicking the icon switches detail pane from terminal to web.
- [ ] Clicking again (or terminal icon) returns to terminal view without losing active shell state.

### Phase 4: Test and Verify

**Files to modify:**
- `/Users/fairchild/code/workspaces/Tests/WorkspaceManagerTests/ModelsTests.swift` - cover new repo web fields and validation helpers.
- `/Users/fairchild/code/workspaces/Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift` - guard shortcut ownership remains unchanged with web mode present (if commands expanded).

**Acceptance criteria:**
- [ ] Unit tests pass for model/config validation.
- [ ] Existing split/sidebar shortcuts (`Cmd+D`, `Cmd+B`) still route correctly in terminal mode.
- [ ] Manual web-mode checks pass for at least one configured repo.

## Verification Commands

```bash
# Build/test baseline
./scripts/build-ghosttykit.sh
swift build
swift test

# Launch debug app without stealing focus (shared desktop safe)
./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'

# Manual checks (future implementation):
# 1) Select repo -> terminal session appears (unchanged)
# 2) Click web icon -> webview replaces terminal
# 3) Click terminal icon -> terminal session returns with prompt/history intact
# 4) Confirm Cmd+B toggles sidebar and Cmd+D creates split in terminal mode

# Capture evidence
./scripts/capture-window.sh
```

## Rollback Plan

1. Remove web-mode routing from `ContentView` and restore terminal-only detail rendering.
2. Remove runtime manager and web view components.
3. Keep repo web fields but stop consuming them (safe soft rollback), or run a follow-up migration to remove fields if required.
4. Re-run `swift test` and shortcut/manual checks to confirm baseline behavior.

## Risks and Mitigations

- Process orphaning risk if app closes while run command is active.
  Mitigation: runtime manager owns `Process` instances and terminates children on shutdown/deinit.

- URL mismatch (server starts on different port than configured).
  Mitigation: display runtime stderr and explicit retry/open-external actions in web container.

- Focus and shortcut regressions between web and terminal modes.
  Mitigation: keep terminal focus pipeline unchanged and limit new shortcuts in v1.

## References

- `/Users/fairchild/code/workspaces/Sources/WorkspaceManagerCore/Models/Models.swift:13`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:73`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:100`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:137`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:482`
- `/Users/fairchild/code/workspaces/docs/development/libghostty-integration.md`
- `/Users/fairchild/code/workspaces/docs/development/shortcut-routing.md`
