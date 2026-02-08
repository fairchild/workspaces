---
status: pending
category: followup
pr: 378
branch: feat/terminal-keyboard-investigation
score: null
retro_summary: null
completed: null
---

# WorkspaceManager Code Review Follow-ups

## Problem Statement

During code review of the terminal keyboard fix (PR #378), several improvements were identified that are safe to defer. These are minor issues that don't affect functionality but would improve code quality, maintainability, and robustness.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Defer vs fix now | Defer | Terminal keyboard works; these are polish items |
| Process blocking | Async pattern | Current waitUntilExit() blocks actor executor |
| Error handling | User-facing alerts | TODOs exist but app works for happy path |

## Implementation Phases

### Phase 1: Async Process Execution

**Problem**: `Process.waitUntilExit()` blocks the actor's executor thread.

**Files to modify:**
- `WorkspaceManager/Sources/Services/GitService.swift:23-37` - `runGit()` method
- `WorkspaceManager/Sources/Services/WorkspaceService.swift` - any Process usage
- `WorkspaceManager/Sources/Services/WorkspaceBackend.swift` - any Process usage

**Pattern to use:**
```swift
func runGit(_ args: [String], at directory: URL) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        // ... configure process ...
        process.terminationHandler = { process in
            if process.terminationStatus == 0 {
                continuation.resume(returning: output)
            } else {
                continuation.resume(throwing: GitError.failed(...))
            }
        }
        try process.run()
    }
}
```

**Acceptance criteria:**
- [ ] No `waitUntilExit()` calls in codebase
- [ ] All Process execution uses terminationHandler with continuation
- [ ] Git operations still work correctly

### Phase 2: User-Facing Error Handling

**Problem**: TODO comments indicate missing error display to users.

**Files to modify:**
- `WorkspaceManager/Sources/Views/MainWindow/SidebarView.swift` - Search for "TODO"

**Pattern to use:**
```swift
.alert("Error", isPresented: $showError) {
    Button("OK") { }
} message: {
    Text(errorMessage)
}
```

**Acceptance criteria:**
- [ ] No TODO comments for error handling remain
- [ ] Errors display in alerts or inline messages
- [ ] User can understand what went wrong

### Phase 3: Code Hygiene

**Files to modify:**

1. `WorkspaceManager/Sources/Views/Components/TerminalView.swift`
   - `TerminalTheme.colors` property is defined but never used
   - Either use it for ANSI color mapping or remove it

2. `WorkspaceManager/Sources/Models/Models.swift`
   - Move `import SwiftUI` from end of file to top with other imports

3. `WorkspaceManager/Sources/Views/MainWindow/SidebarView.swift`
   - Remove redundant `extension Repo: Identifiable {}` (Repo already conforms via SwiftData @Model)
   - Remove redundant `extension Workspace: Identifiable {}` (same reason)

4. `WorkspaceManager/Sources/Views/MainWindow/RightPaneView.swift`
   - `FileNode` uses path-only equality but has UUID id
   - Consider if this could cause issues in SwiftUI diffing
   - Either use id in equality or document why path-only is correct

**Acceptance criteria:**
- [ ] No unused properties
- [ ] Imports at top of files
- [ ] No redundant protocol conformances
- [ ] Consistent equality/identity semantics

### Phase 4: Unit Tests ✅

**Problem**: No unit tests exist for core services.

**Files created:**
- `WorkspaceManager/Tests/GitServiceTests.swift` (11 tests)
- `WorkspaceManager/Tests/WorkspaceServiceTests.swift` (8 tests)
- `WorkspaceManager/Tests/ModelsTests.swift` (17 tests)

**Test coverage:**
- GitService: Status parsing, branch detection, file tree building, error handling
- WorkspaceService: Lifecycle scripts, filename sanitization
- Models: FileChange, GitStatus, WorkspaceStatus, FileNode

**Acceptance criteria:**
- [x] Tests directory created with proper Package.swift testTarget
- [x] At least 3 tests per service (36 total tests)
- [ ] Tests pass in CI (needs verification)

## Verification Commands

```bash
cd /Users/fairchild/code/services/workspaces/WorkspaceManager

# Build
swift build

# Run tests (after Phase 4)
swift test

# Search for remaining TODOs
grep -r "TODO" Sources/

# Search for waitUntilExit
grep -r "waitUntilExit" Sources/
```

## Rollback Plan

These are all additive improvements. If any cause issues:
1. Revert the specific commit
2. The terminal keyboard fix remains unaffected

## References

- PR #378: Terminal keyboard fix (merged baseline)
- `docs/solution-terminal-keyboard.md`: Documents the focus management approach
- `docs/progress.md`: Investigation history
