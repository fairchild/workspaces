---
status: completed
category: plan
pr: 36
branch: codex/apple-native-main-window-redesign-backlog
score: null
retro_summary: Implemented on the redesign branch with repo overview as the primary repo surface, scoped web views, calmer sidebar chrome, removal of the Recent section, and deterministic launch/selection hardening.
completed: 2026-03-10
topic: apple-native-main-window-redesign
priority: 1
description: Redesign the main window and adjacent flows so Workspaces feels calmer, clearer, and more Apple-native without compromising terminal-first behavior.
---

# Terminal-First Apple-Native Main Window Redesign

## Problem Statement

Workspaces already gets the hardest product decision right: the terminal is the product. The current main window works functionally, but the surrounding chrome is not yet as calm, clear, or native as the core workflow deserves. The sidebar uses large bold labels, saturated icons, multiple badge types, and persistent footer actions; the main title often collapses to a generic `Host`; and the right pane uses custom tab chrome that reads more custom than system.

This creates three user-flow problems:

- first-run and return-to-work navigation are visually noisier than necessary
- the app does not establish current working context strongly enough when switching between host, repo, and workspace
- support surfaces (sidebar, inspector, sheets) compete with the terminal instead of deferring to it

The redesign should keep the existing three-column architecture and terminal-first behavior, but make the UI feel more like a first-party Apple tool: calmer, more obvious, more semantic, and more system-native.

## Implementation Status

This plan was implemented on `codex/apple-native-main-window-redesign-backlog` and is retained as the design/handoff record for what shipped. The final implementation deliberately diverged from a few early ideas in this document:

- `Host` is no longer a visible top-level navigation concept.
- The `Recent` section was removed instead of being elevated.
- Repo overview is the primary repo destination.
- Repo/web/workspace navigation is flatter and quieter than the initial grouped proposal.

Validation on the branch included build/test runs plus live debug-app launch, screenshot capture, and `Cmd+B` / `Cmd+D` runtime checks.

## Single-Input Handoff Contract

This document is intended to be the single prompt/input for a fresh coding agent. The implementing agent should not need the original conversation. Treat the decisions, references, and observations below as the authoritative design brief and implementation plan.

## Referenced Skills To Apply

Before making UI changes, open and apply these skills:

- `/Users/fairchild/.agents/skills/apple-ui-designer/SKILL.md`
- `/Users/fairchild/.agents/skills/apple-hig-designer/SKILL.md`

Distilled guidance from those skills that should drive this work:

- Native over custom. Prefer system-looking SwiftUI/AppKit controls and macOS idioms over bespoke chrome.
- Calm, confident hierarchy. Use typography, spacing, and material depth before color or decoration.
- Deference. The terminal/session content is primary; sidebar, header, inspector, and sheets should orient the user without competing with the canvas.
- Clarity. Make current context, primary actions, and selection state obvious at a glance.
- Depth. Use subtle material, separation, and motion to explain hierarchy, not to decorate.
- Semantic typography and color. Prefer system text styles and semantic colors; avoid hard-coded visual loudness where system styles will do.
- Accessibility. Preserve contrast, VoiceOver semantics, keyboard accessibility, and clear target sizing.
- Do not cargo-cult iPhone UI onto macOS. Translate the Apple-language goals into native desktop patterns: source list, toolbar, split view, inspector, and sheets.

## What We Learned

### Product And Architecture Facts

- Workspaces is explicitly terminal-first and uses a three-column layout: sidebar, terminal/detail, inspector.
- Current behavior from `README.md` and code:
  - launch restores the last active surface or falls back to a repo overview
  - sidebar selection opens repo overviews, web views, or resumes persistent terminal sessions
  - right pane shows files and git changes
  - workspace creation and URL-source creation happen in sheets
- Current implementation anchors:
  - `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:206` defines the `NavigationSplitView`
  - `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:230` and `:262` define toolbar groups
  - `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:982` defines `MainTerminalDetailView`
  - `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:1027` sets `.navigationTitle(selectedWorkspace?.name ?? "Host")`
  - `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:78` starts the `Repositories` section
  - `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:215` starts the `Web` section
  - `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:256` defines the persistent bottom inset actions
  - `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:69` and `:96` define workspace and pane badges
  - `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:119`, `:159`, and `:219` define host, repo, and workspace row treatments
  - `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift:49`, `:57`, and `:217` define the inspector and its custom tab buttons
  - `Sources/WorkspaceManager/Views/Components/WorkspaceEditorToolbarButton.swift:4`, `:14`, and `:29` define the current editor/open control group
  - `Sources/WorkspaceManager/Views/MainWindow/NewWorkspaceSheet.swift:32`, `:74`, `:92`, and `:118` define the workspace-creation sheet
  - `Sources/WorkspaceManager/Views/MainWindow/NewWebSourceSheet.swift:10`, `:30`, and `:79` define the URL-source sheet

### Screenshot Summary

The reviewed screenshot showed:

- a large, dark terminal surface that already feels like the correct focal point
- a bright/light sidebar with large bold repository names, strong blue icons, multiple badges, and visible bottom add actions
- a generic `Host` title in the window toolbar
- no persistent working-context header above the terminal
- the inspector hidden, which makes the current right-pane affordance feel secondary and easy to miss

### Design Findings From The Review

- Keep:
  - the terminal as the hero surface
  - the three-column split model
  - persistent host/repo/workspace sessions
  - the files/changes inspector concept
- Change:
  - the sidebar should become a calmer macOS source list
  - the main working context needs stronger identity than a generic title
  - the inspector should read like a native macOS inspector, not a custom tab bar
  - first-run/add/create flows need more guided, Apple-like framing
- Avoid:
  - overdesigned chrome
  - trendy card stacks, neon accents, or mobile-style bottom navigation
  - turning the app into a git client or adding unrelated scope

## Design Contract

### Screen 1: Main Window (Host/Repo/Workspace Active)

Design intent:

- A browser-canvas-inspector layout where the user always knows what context they are in while the terminal remains dominant.

Required structure:

- Sidebar on the left as a calm source list.
- Main canvas in the middle with a compact context header above the terminal/code-preview area.
- Inspector on the right for files and changes.
- Toolbar actions limited to contextually relevant actions.

Typography and visual rules:

- Use system typography and semantic colors.
- Use semibold only for the active or selected primary label.
- Prefer monochrome symbols with small, purposeful status accents.
- Let spacing, material, and selection state carry hierarchy instead of multiple bright badges.

Interaction and motion:

- Preserve terminal focus on selection changes.
- Sidebar/inspector visibility changes should use standard split-view motion only.
- Context changes should update header metadata without dramatic layout shifts.

Native reasoning:

- This maps Apple HIG clarity/deference/depth to macOS rather than copying iOS chrome patterns.

### Screen 2: First-Run / Empty State

Design intent:

- Make the first action obvious and low-friction: add a repository.

Required structure:

- Centered empty state with a single primary action `Add Repository`.
- Secondary affordance to import from `~/code` if appropriate.
- Minimal explanation of what Workspaces does.

Native reasoning:

- Apple first-run flows favor one clear next step, not scattered affordances.

### Screen 3: Creation Sheets

Design intent:

- Use standard, calm sheets that default intelligently and return the user to work quickly.

Required structure:

- `NewWorkspaceSheet` should foreground the selected repo, suggested name, and environment choice without decorative weight.
- `NewWebSourceSheet` should feel clearly secondary to the core coding loop.

Native reasoning:

- Standard form rhythm, clear primary action, low ornamentation.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Product hierarchy | Keep terminal as the hero surface | The product's value is session management around a terminal, not the chrome itself |
| Window architecture | Keep the existing three-column split view | The current information architecture is correct; the problem is hierarchy and treatment |
| Context framing | Add a compact context header above the terminal | Users need stronger "where am I?" cues than `Host` or toolbar fragments |
| Sidebar treatment | Restyle as a calmer macOS source list | Current row styling is too visually loud and slows scanning |
| Sidebar sections | Elevate `Host` and `Active/Recent`; keep `Repositories`; demote `Web` | This matches the actual coding loop and makes return-to-work faster |
| Footer actions | Move add actions into a more native `+`/toolbar pattern | Permanent footer ownership is too visually strong for infrequent actions |
| Inspector | Replace custom tab pills with a native macOS inspector treatment | Current tabs look custom; the inspector should feel built-in |
| Flow scope | Polish first-run and creation sheets as part of the same pass | The screenshot alone is not enough; user flow matters |
| Skill usage | Require `apple-ui-designer` and `apple-hig-designer` guidance up front | The design brief should stay anchored to Apple-native principles |
| Safety | Preserve existing keyboard shortcuts, split behavior, and session routing | The redesign must not regress the terminal-first daily-driver workflow |

## Architecture

```text
Window
├─ Sidebar (source list)
│  ├─ Host
│  ├─ Active / Recent
│  ├─ Repositories
│  │  └─ Nested workspaces
│  └─ Web (secondary / collapsed when appropriate)
├─ Main canvas
│  ├─ Context header
│  │  ├─ icon + title
│  │  ├─ path / repo / branch / state metadata
│  │  └─ Open / Split / Inspector actions
│  └─ Terminal stack
│     └─ Optional code preview split
└─ Inspector
   ├─ Files
   └─ Changes
```

```text
Primary flow
Launch -> Host terminal
  -> Select repo
     -> Resume repo session
        -> Create workspace (optional)
           -> Resume workspace session
              -> Inspect files/changes or preview code
```

## Implementation Phases

### Phase 1: Codify A Terminal-First Context Header And Toolbar Contract

**Files to modify:**

- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - introduce or wire a compact context header for host/repo/workspace; reduce reliance on the generic navigation title; align toolbar actions with the active context.
- `Sources/WorkspaceManager/Views/Components/WorkspaceEditorToolbarButton.swift` - simplify the editor/open control so it fits the new context model.
- `Sources/WorkspaceManager/Views/MainWindow/HostTerminalSessionStack.swift` - adjust only if needed to support cleaner header-to-terminal separation.

**Files to create (if helpful):**

- `Sources/WorkspaceManager/Views/MainWindow/MainWindowContextHeader.swift` - isolate the new header presentation and keep `ContentView.swift` from growing again.

**Acceptance criteria:**

- [ ] Host, repo, and workspace contexts each present a clear title and secondary metadata without pulling focus from the terminal.
- [ ] The window no longer relies on `Host` as the only identity cue for the active session.
- [ ] Open-in-editor, split, and inspector actions feel grouped and contextually obvious.
- [ ] Terminal focus behavior is unchanged.

### Phase 2: Redesign The Sidebar As A Calmer macOS Source List

**Files to modify:**

- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift` - rework section hierarchy and bottom action placement; consider `Active` or `Recent` grouping before full repositories.
- `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift` - reduce visual weight of icons, labels, and badges; make selected/active states clearer and quieter.
- `Sources/WorkspaceManager/Views/MainWindow/WebSourceRow.swift` - make web rows match the calmer sidebar treatment.

**Acceptance criteria:**

- [ ] The sidebar reads as supporting chrome, not a competing focal area.
- [ ] `Host` is clearly the default/root context and `~/code` is secondary metadata.
- [ ] Repo/workspace rows are faster to scan, with fewer simultaneous color/badge signals.
- [ ] `Add Repository` and `Add URL Source` no longer dominate the sidebar footer.
- [ ] `Web` feels secondary to the primary coding loop.

### Phase 3: Make The Right Pane Read As A Native Inspector

**Files to modify:**

- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift` - replace custom tab-pill styling with a more native inspector header/toggle treatment; improve summary copy for file/change state.
- `Sources/WorkspaceManager/Views/MainWindow/CodeFilePreviewView.swift` - ensure preview chrome matches the redesigned inspector/canvas relationship.
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - keep inspector visibility behavior coherent with the new treatment.

**Files to create (if helpful):**

- `Sources/WorkspaceManager/Views/MainWindow/InspectorHeaderView.swift` - shared header treatment for files/changes state.

**Acceptance criteria:**

- [ ] The right pane reads immediately as an inspector.
- [ ] `Files` and `Changes` switching uses standard system-looking controls.
- [ ] Count/status summaries are clearer without adding clutter.
- [ ] Preview and inspector both remain visibly secondary to the terminal.

### Phase 4: Polish First-Run And Creation-Sheet Flow

**Files to modify:**

- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift` - improve zero-state/empty-state treatment when no repos exist.
- `Sources/WorkspaceManager/Views/MainWindow/NewWorkspaceSheet.swift` - refine hierarchy, copy, default selection, and form rhythm.
- `Sources/WorkspaceManager/Views/MainWindow/NewWebSourceSheet.swift` - align with the calmer sheet treatment and ensure it stays visually secondary.

**Acceptance criteria:**

- [ ] The first meaningful action on first launch is obvious.
- [ ] The new-workspace sheet feels native, direct, and minimally ornamental.
- [ ] The URL-source sheet feels consistent with the window redesign without becoming more prominent than it should be.
- [ ] Returning from sheet completion puts users back into the terminal flow cleanly.

### Phase 5: Regression Coverage And Implementation Hygiene

**Files to modify:**

- `Tests/WorkspaceManagerAppTests/MainWindowPresentationControllerTests.swift` - protect context-derivation and selection presentation rules if new helpers/controllers are extracted.
- `Tests/WorkspaceManagerAppTests/SidebarSessionPresentationTests.swift` - cover any revised session indicator or section-derivation logic.
- `Tests/WorkspaceManagerAppTests/SidebarViewTests.swift` - preserve workspace/repo/sidebar action behavior when visual structure changes.
- `Tests/WorkspaceManagerAppTests/InspectorStateControllerTests.swift` - protect inspector target visibility/selection rules.
- `Tests/WorkspaceManagerAppTests/RightPaneStateStoreTests.swift` - preserve inspector-session state behavior.
- `Tests/WorkspaceManagerAppTests/OpenInEditorShortcutFlowTests.swift` and `Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift` - keep editor/shortcut behavior stable if toolbar/context routing changes.

**Acceptance criteria:**

- [ ] The redesign is backed by deterministic controller/state tests where logic moves out of views.
- [ ] `swift test` remains green.
- [ ] The pass improves or preserves maintainability rather than packing more logic into `ContentView.swift` and `SidebarView.swift`.

## Verification Commands

Because this work touches sidebar/terminal behavior, use the required development verification loop from the repo instructions.

```bash
./scripts/build-ghosttykit.sh
swift build
swift test

./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'

# Manual verification in the debug build:
# - Cmd+B toggles the left sidebar
# - Cmd+D creates a visible right split for the focused terminal
# - Host/repo/workspace selection still focuses the expected terminal
# - The redesigned main window keeps the terminal visually dominant
# - Inspector visibility and files/changes switching still work

# If split verification fails, inspect logs for split routing
rg -n "\\[GhosttyAppManager\\] action=new_split direction=" .dev-data/logs

./scripts/capture-window.sh
```

## Rollback Plan

1. Keep the three-column split architecture and session-routing behavior as invariants.
2. If the redesign destabilizes interaction behavior, revert presentation-only changes first:
   - context header
   - sidebar styling/section treatment
   - inspector header/toggle treatment
3. If extracted helpers improve maintainability but a specific visual treatment misses the mark, keep the extractions and roll back only the view-layer styling.
4. Do not roll back keyboard shortcut, split-routing, or session-focus fixes as part of visual iteration.

## References

### Product And Code References

- `README.md`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:206`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:230`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:262`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:982`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:1027`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:78`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:215`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift:256`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:69`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:96`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:119`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:159`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift:219`
- `Sources/WorkspaceManager/Views/MainWindow/WebSourceRow.swift`
- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift:49`
- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift:57`
- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift:217`
- `Sources/WorkspaceManager/Views/Components/WorkspaceEditorToolbarButton.swift:4`
- `Sources/WorkspaceManager/Views/MainWindow/NewWorkspaceSheet.swift:32`
- `Sources/WorkspaceManager/Views/MainWindow/NewWebSourceSheet.swift:10`

### Tests And Docs

- `Tests/WorkspaceManagerAppTests/MainWindowPresentationControllerTests.swift`
- `Tests/WorkspaceManagerAppTests/SidebarSessionPresentationTests.swift`
- `Tests/WorkspaceManagerAppTests/SidebarViewTests.swift`
- `Tests/WorkspaceManagerAppTests/InspectorStateControllerTests.swift`
- `Tests/WorkspaceManagerAppTests/RightPaneStateStoreTests.swift`
- `Tests/WorkspaceManagerAppTests/OpenInEditorShortcutFlowTests.swift`
- `Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift`
- `docs/development/libghostty-integration.md`
- `docs/development/shortcut-routing.md`
- `docs/development/solution-terminal-keyboard.md`
- `backlog/main-window-sidebar-maintainability_followup.md`

### Skill References

- `/Users/fairchild/.agents/skills/apple-ui-designer/SKILL.md`
- `/Users/fairchild/.agents/skills/apple-hig-designer/SKILL.md`
