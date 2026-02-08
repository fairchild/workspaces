# Workspace Manager — Progress

## Status: MVP Nearly Complete

Tasks 1-9.5 are implemented. Only error handling (Task 10) and distribution (Task 11) remain.

---

## What Works

### Core Features

- ✅ App builds and runs
- ✅ Three-column layout (sidebar, terminal, right pane)
- ✅ SwiftTerm terminal renders correctly
- ✅ Terminal keyboard input (Ghostty-style focus management)
- ✅ Add git repositories via folder picker
- ✅ Create workspaces (directory copy + optional setup.sh)
- ✅ Workspace selection switches terminal directory
- ✅ File tree view with collapsible directories
- ✅ Git status view with change icons
- ✅ Tab switching between Files and Changes
- ✅ Settings with configurable workspace location
- ✅ Context menus for repos and workspaces

### Unit Tests

Added Swift Testing tests for core services:

| File | Tests | Coverage |
|------|-------|----------|
| `Tests/GitServiceTests.swift` | 11 | Status parsing, branches, file tree |
| `Tests/WorkspaceServiceTests.swift` | 8 | Lifecycle scripts, filename sanitization |
| `Tests/ModelsTests.swift` | 17 | FileChange, GitStatus, WorkspaceStatus, FileNode |

---

## Terminal Keyboard Solution

SwiftUI intercepts keyboard events before they reach embedded AppKit views. The solution (inspired by Ghostty) uses:

1. **TerminalFocusManager** - Centralized focus with retry logic
2. **NSEvent Local Monitor** - Intercept keyboard events, forward to terminal
3. **Global Click Monitor** - Activate app when clicked from other apps

See `docs/development/solution-terminal-keyboard.md` for details.

---

## What Remains

### MVP (Required)

| Task | Status | Notes |
|------|--------|-------|
| Task 10: Error Handling | Pending | Multiple TODOs in SidebarView for user-facing alerts |
| Task 11: Build & Distribution | Pending | Requires Apple Developer account |

### Tech Debt (Optional)

| Item | Status | Notes |
|------|--------|-------|
| Async Process Execution | Pending | Replace `waitUntilExit()` with terminationHandler |
| Code Hygiene | Pending | Unused properties, import ordering |
| Keyboard Shortcuts | Pending | Cmd+0 to toggle pane not implemented |

---

## Task Summary

| Task | Status |
|------|--------|
| 1. Foundation + Terminal | ✅ |
| 2. Three-Column Layout | ✅ |
| 3. SwiftData Persistence | ✅ |
| 4. Add Repository Flow | ✅ |
| 5. Workspace Creation | ✅ |
| 6. Terminal Switching | ✅ |
| 7. File Tree | ✅ |
| 8. Git Status | ✅ |
| 9. Tab Switching | ✅ |
| 9.5. Settings | ✅ |
| 10. Error Handling | ⏳ |
| 11. Distribution | ⏳ |

---

## References

- [Terminal Keyboard Solution](../docs/development/solution-terminal-keyboard.md)
- [Code Review Followup](workspaces-code-review-followup.md)
- [TASKS.md](../TASKS.md)
