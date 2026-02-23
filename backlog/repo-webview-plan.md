---
status: pending
category: plan
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# URL Sources + Embedded Webview (MPP)

## Problem Statement

The app is terminal-first and currently assumes sidebar entries are local git repositories. We also need a first-class web browsing flow where users can add a URL source, click it in the sidebar, and browse inside the app without leaving Workspaces.

For MPP scope, this feature should start at domain-level only (single URL source per entry). Workspace-like "new folder/new tab" behavior for websites is explicitly deferred until after MPP.

## Why Deferred

- Current request is to produce an executable implementation plan before writing feature code.
- This change affects persistence schema, selection routing, and detail-pane rendering, so a locked execution plan reduces rework.

## Scope Lock (MPP)

### In Scope

- Add URL sources from UI (example: `https://docs.example.com`).
- Show URL sources in sidebar and allow selecting them.
- Render selected URL source in embedded `WKWebView`.
- Restrict in-app navigation to the configured domain (and optional subdomains).
- Keep terminal/repo/workspace flows unchanged.
- Keep startup and non-web usage overhead minimal.

### Out of Scope (Post-MPP Follow-up)

- Repo run-command integration for web servers.
- Website "new workspace" cloning/folder/tab UX.
- Multi-tab browser model.
- Cross-source shared auth/session management.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Data model | Add separate `WebSource` SwiftData model | Avoids overloading `Repo` and reduces migration risk to existing terminal flows. |
| Selection model | Add explicit top-level selection enum (`host/repo/workspace/web`) | Removes ambiguity and keeps routing deterministic. |
| Browser policy | Domain-locked navigation for each source | Matches requirement: browse within configured domain. |
| Performance default | WebKit objects are created only when first web source is selected | Keeps app launch and terminal-first flow unaffected when web is unused. |
| Memory default | Single active web surface with lightweight state retention | Prevents unbounded memory growth from hidden webviews. |
| MPP boundary | Defer website workspaces/tabs | Focuses release scope and protects schedule. |

## Architecture

```text
Sidebar Selection
   -> Repo/Workspace/Host: existing terminal activation path (unchanged)
   -> WebSource: select web source, do not activate terminal session

Main Detail Router
   -> terminal selections: existing MainTerminalDetailView
   -> web selection: new WebSourceDetailView

WebSourceDetailView
   -> WebSurfaceStore.ensureSurface(for: source.id)
   -> lazy-create WKWebView on first use
   -> enforce domain lock via WKNavigationDelegate
   -> reuse single active surface when switching away/back
```

## Current Code Findings

- Repo model has no web config fields yet: `/Users/fairchild/code/workspaces/Sources/WorkspaceManagerCore/Models/Models.swift:13`
- Repo selection and host session activation happen in `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:137`
- Main detail pane is terminal-only today: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:482`
- Repo row currently has one action surface (select terminal) and no secondary icon: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:100`
- Repo context menu has no "web config" entry yet: `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:92`

## Implementation Phases

### Phase 1: Add URL Source Data Model + Persistence

**Files to modify:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManagerCore/Models/Models.swift`
  Add `WebSource` model:
  - `id: UUID`
  - `name: String`
  - `baseURLString: String`
  - `allowedHost: String`
  - `addedAt: Date`
  - `lastAccessedAt: Date`
  Also add URL/host normalization helpers.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/App/WorkspaceManagerApp.swift`
  Include `WebSource` in `Schema([...])`.

**Files to create:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManagerCore/Models/WebSourceValidation.swift`
  URL parsing + host extraction utility for strict validation.

**Acceptance criteria:**
- [ ] Existing app data opens successfully after schema update.
- [ ] URL sources can be persisted and reloaded across launches.
- [ ] Invalid URL/domain input is rejected with actionable error text.

### Phase 2: Sidebar UX for URL Sources (Add + Select)

**Files to create:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/NewWebSourceSheet.swift`
  UI to enter URL and optional display name.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/WebSourceRow.swift`
  Globe + domain row view.

**Files to modify:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift`
  Add `Web` section and add/remove actions.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift`
  Keep repo rows unchanged; add web row usage where needed.

**Acceptance criteria:**
- [ ] User can add a URL source from sidebar.
- [ ] Web source appears in list with domain label.
- [ ] Selecting a web source does not alter active terminal sessions.

### Phase 3: Detail Routing + Embedded Browser

**Files to create:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/Components/WebSourceView.swift`
  `NSViewRepresentable` wrapper for `WKWebView`.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Web/WebNavigationPolicy.swift`
  Domain-restriction delegate and external-open fallback.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Web/WebSurfaceStore.swift`
  Creates/retains web surfaces lazily and exposes lightweight lifecycle controls.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/WebSourceDetailView.swift`
  Loading/error chrome for web mode.

**Files to modify:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
  Introduce primary selection enum and branch detail view:
  - terminal path (existing)
  - web path (new)
- `/Users/fairchild/code/workspaces/Package.swift`
  Link `WebKit`.

**Acceptance criteria:**
- [ ] Selecting a URL source renders in-app web content.
- [ ] Navigation is blocked outside allowed domain/subdomains.
- [ ] Blocked links open externally or show clear blocked-state messaging.
- [ ] Returning to terminal selections restores existing terminal UI unchanged.

### Phase 4: Performance and Memory Hardening (MPP Gate)

**Files to modify:**
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Diagnostics/PerformanceSignposts.swift`
  Add optional web signposts (`webViewInit`, `webFirstLoad`) for profiling.
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Web/WebSurfaceStore.swift`
  Add explicit `releaseInactiveSurface()` path.
- `/Users/fairchild/code/workspaces/Tests/WorkspaceManagerTests/ModelsTests.swift`
  Validate URL parsing/normalization behavior.
- `/Users/fairchild/code/workspaces/Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift`
  Ensure app/terminal shortcut behavior is unchanged.

**Acceptance criteria:**
- [ ] App launch path remains unchanged when no URL source is selected.
- [ ] No `WKWebView` instance exists before first web selection.
- [ ] Memory does not grow unbounded when toggling between terminal and web mode repeatedly.
- [ ] `Cmd+B` and `Cmd+D` behavior remains correct in terminal mode.

## Performance Architecture Notes

- Keep all WebKit types isolated in `Sources/WorkspaceManager/Web/*` and web-specific views.
- `WebSurfaceStore` must be created with empty state at launch and instantiate `WKWebView` only on first web selection.
- Cap active surfaces to 1 for MPP (recreate or swap URL on source change) to avoid idle-surface accumulation.
- Provide explicit surface teardown when web mode is not active for a sustained interval.
- Do not modify Ghostty surface store behavior in MPP; web and terminal lifecycles stay independent.
- Add profiling checkpoints to compare launch timing before and after web feature merge.

## Verification Commands

```bash
# Build/test baseline
./scripts/build-ghosttykit.sh
swift build
swift test

# Launch debug app without stealing focus (shared desktop safe)
./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'

# Manual checks (MPP implementation):
# 1) Add URL source and confirm sidebar entry appears
# 2) Select URL source and confirm web content renders in app
# 3) Attempt off-domain link and confirm block/external-open behavior
# 4) Switch back to repo/workspace and confirm terminal session continuity
# 5) Confirm Cmd+B toggles sidebar and Cmd+D split remains terminal-only

# Capture evidence
./scripts/capture-window.sh
```

## Rollback Plan

1. Remove URL source sections from sidebar and selection routing from `ContentView`.
2. Remove WebKit-linked components and `WebSurfaceStore`.
3. Keep `WebSource` model unused (soft rollback) or remove with explicit migration follow-up.
4. Re-run `swift test` and terminal shortcut/manual verification.

## Risks and Mitigations

- WebKit baseline overhead could affect memory if always active.
  Mitigation: lazy-create surfaces, cap to one active surface, and release when inactive.

- Domain rule may be too strict/too loose for real sites.
  Mitigation: implement deterministic host matching with test coverage and explicit allow-subdomain policy.

- Selection routing regressions may break terminal behavior.
  Mitigation: isolate selection enum changes and preserve existing terminal activation paths untouched.

- MPP timeline risk if website-workspace behavior leaks into scope.
  Mitigation: hard defer website workspaces/tabs to follow-up milestone.

## Post-MPP Follow-up (Already Requested)

After MPP release, create a follow-up plan for:

- Website "new workspace" action that creates a folder context.
- Website sessions represented as tab-like units in sidebar/detail.
- Memory policy for multiple web sessions (LRU + persisted tab state).

## References

- `/Users/fairchild/code/workspaces/Sources/WorkspaceManagerCore/Models/Models.swift:13`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/App/WorkspaceManagerApp.swift:15`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:73`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:100`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:137`
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:482`
- `/Users/fairchild/code/workspaces/docs/development/libghostty-integration.md`
- `/Users/fairchild/code/workspaces/docs/development/shortcut-routing.md`
