# WorkspaceManager - Agent Context

Mac-native app for managing AI coding sessions with embedded terminal.

## Quick Commands

```bash
cd WorkspaceManager && swift build   # Build
cd WorkspaceManager && swift test    # Test
cd WorkspaceManager && swift run     # Run
```

## Doc Navigation

| Task | Primary Doc | Skip |
|------|-------------|------|
| Understand the app | README.md | SPECS.md, backlog/ |
| Architectural decisions | ARCHITECTURE.md | backlog/ |
| Implement a component | SPECS.md (find relevant section) | Read whole file |
| Debug an issue | docs/development/troubleshooting.md | - |
| Terminal keyboard focus | docs/development/solution-terminal-keyboard.md | - |
| Roadmap/planning | backlog/ROADMAP.md, backlog/progress.md | - |
| Deferred work items | backlog/*.md | - |

## Code Navigation

| What | Where |
|------|-------|
| Data models | WorkspaceManager/Sources/Models/Models.swift |
| Git operations | WorkspaceManager/Sources/Services/GitService.swift |
| Workspace lifecycle | WorkspaceManager/Sources/Services/WorkspaceService.swift |
| Main layout | WorkspaceManager/Sources/Views/MainWindow/ContentView.swift |
| Terminal wrapper | WorkspaceManager/Sources/Views/Components/TerminalView.swift |
| Sidebar (repos/workspaces) | WorkspaceManager/Sources/Views/MainWindow/SidebarView.swift |
| Right pane (files/changes) | WorkspaceManager/Sources/Views/MainWindow/RightPaneView.swift |
| Tests | WorkspaceManager/Tests/*.swift |

## Key Patterns

1. **URL Storage**: SwiftData can't store URLs directly. Store as String, access via computed property:
   ```swift
   var path: String  // stored
   var workspaceURL: URL { URL(fileURLWithPath: path) }  // computed
   ```

2. **Actors for Services**: GitService and WorkspaceService are actors for async safety. Always use `await`.

3. **Terminal Recreation**: Use `.id(workspace.id)` to force terminal recreation when workspace changes.

4. **Keyboard Focus**: Ghostty-style retry-based focus restoration. See `docs/development/solution-terminal-keyboard.md`.

## Tech Stack

- **UI**: SwiftUI + AppKit hybrid
- **Terminal**: SwiftTerm 1.5.1
- **Persistence**: SwiftData
- **Target**: macOS 14.0+
- **Distribution**: Direct (non-sandboxed, App Store sandbox blocks shell execution)

## Don't

- Don't modify Package.swift unless adding dependencies
- Don't read SPECS.md entirely - find the component you need
- Don't put service logic in Views - use Services/
- Don't store URLs directly in SwiftData models
