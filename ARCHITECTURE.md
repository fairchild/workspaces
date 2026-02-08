# Workspace Manager — Architecture

## Design Principles

1. **Terminal-first**: The embedded terminal is the primary experience, not a code editor
2. **Native feel**: Use AppKit/SwiftUI patterns, feel like a Mac app
3. **Simple data model**: Repos → Workspaces → Files, nothing more
4. **Offline-first**: Works without internet (git remotes optional)
5. **Non-destructive**: Never delete user's source repos

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         WorkspaceManagerApp                         │
│                    (SwiftUI App + AppDelegate)                      │
├─────────────────────────────────────────────────────────────────────┤
│                           ContentView                               │
│                      (NavigationSplitView)                          │
├──────────────┬──────────────────────────────┬───────────────────────┤
│  SidebarView │     TerminalContainerView    │    RightPaneView      │
│              │                              │                       │
│  ┌────────┐  │  ┌────────────────────────┐  │  ┌─────────────────┐  │
│  │ Repos  │  │  │                        │  │  │ [Files][Changes]│  │
│  │ ------─│  │  │    TerminalView        │  │  ├─────────────────┤  │
│  │ repo1  │  │  │   (SwiftTerm PTY)      │  │  │                 │  │
│  │ repo2  │  │  │                        │  │  │  FileTreeView   │  │
│  ├────────┤  │  │  $ claude              │  │  │       or        │  │
│  │Workspcs│  │  │  > Working...          │  │  │ ChangedFilesView│  │
│  │ ------─│  │  │                        │  │  │                 │  │
│  │ ws-1   │  │  └────────────────────────┘  │  └─────────────────┘  │
│  │ ws-2   │  │                              │                       │
│  └────────┘  │                              │                       │
└──────────────┴──────────────────────────────┴───────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          Services Layer                             │
├─────────────────┬──────────────────────┬────────────────────────────┤
│   GitService    │  WorkspaceService    │    (Future: Backends)      │
│   (actor)       │  (actor)             │                            │
│                 │                      │                            │
│  • getStatus()  │  • createWorkspace() │    LocalBackend            │
│  • getFileTree()│  • deleteWorkspace() │    DockerBackend           │
│  • getBranch()  │  • copyRepo()        │    AppleContainerBackend   │
└─────────────────┴──────────────────────┴────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         SwiftData Layer                             │
├─────────────────────────────────────────────────────────────────────┤
│  ModelContainer                                                     │
│  ├── Repo (id, name, localPath, remoteURL, addedAt)                 │
│  └── Workspace (id, name, path, sourceRepo, status, gitBranch)      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Key Technical Decisions

### 1. SwiftUI + AppKit Hybrid

**Decision**: Use SwiftUI for views, AppKit for app/window lifecycle.

**Rationale**:
- SwiftUI's `NavigationSplitView` works well for three-column layouts
- AppKit gives better control over window management
- SwiftTerm provides `LocalProcessTerminalView` (NSView), wrapped via `NSViewRepresentable`

**Pattern**:
```swift
// App entry uses SwiftUI
@main
struct WorkspaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // ...
}

// Terminal wrapped for SwiftUI
struct TerminalView: NSViewRepresentable {
    func makeNSView(context: Context) -> LocalProcessTerminalView { ... }
}
```

### 2. SwiftTerm for Terminal

**Decision**: Use SwiftTerm's `LocalProcessTerminalView` for embedded terminal.

**Rationale**:
- Production-proven (used by La Terminal, Secure Shellfish)
- Handles PTY correctly (don't roll your own)
- Provides complete VT100/xterm emulation
- Active maintenance by Miguel de Icaza

**Key Implementation Details**:

Terminal recreation on workspace change:
```swift
// Terminal must be recreated when workspace changes
// (can't change working directory mid-session)
TerminalView(workingDirectory: workspace.workspaceURL)
    .id(workspace.id)  // Forces recreation
```

Keyboard focus (Ghostty-style):
```swift
// SwiftUI intercepts keyboard events before AppKit views.
// Solution: TerminalFocusManager + NSEvent monitors.
// See docs/development/solution-terminal-keyboard.md for full details.
```

### 3. SwiftData for Persistence

**Decision**: Use SwiftData with simple models.

**Rationale**:
- Native to Swift, no external dependencies
- Automatic migrations
- Works with SwiftUI's `@Query`

**Gotcha**: URLs must be stored as Strings:
```swift
@Model
class Workspace {
    var path: String  // Stored
    
    var workspaceURL: URL {  // Computed
        URL(fileURLWithPath: path)
    }
}
```

### 4. Services as Actors

**Decision**: GitService and WorkspaceService are Swift actors.

**Rationale**:
- File system and git operations are naturally async
- Actor isolation prevents data races
- Clean async/await API

**Pattern**:
```swift
actor GitService {
    static let shared = GitService()
    
    func getStatus(at path: URL) async throws -> [FileChange] {
        // Safe to call from any thread
    }
}

// Usage
let changes = try await GitService.shared.getStatus(at: workspace.workspaceURL)
```

### 5. Workspace Isolation via Abstraction

**Decision**: Define `WorkspaceBackend` protocol now, implement local-only for MVP.

**Rationale**:
- Apple Container (macOS 26) will be the ideal backend
- Docker is a good fallback
- Abstraction allows adding backends without changing app code

**MVP**: Only `LocalBackend` (no isolation, direct filesystem access)

**Future**:
```swift
protocol WorkspaceBackend: Actor {
    func start(workspace: Workspace) async throws
    func execute(command: [String], ...) async throws -> ProcessResult
    func createTerminal(for: Workspace) async throws -> BackendTerminal
}
```

### 6. Non-Sandboxed Distribution

**Decision**: Distribute directly (not App Store), disable sandbox.

**Rationale**:
- App Store sandbox prevents shell execution
- All IDEs do this (VS Code, Xcode, Sublime, etc.)
- Notarization still provides security verification

**Entitlements**:
```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
```

### 7. Terminal Focus Management (Ghostty-Style)

**Decision**: Use centralized focus manager with event monitors.

**Rationale**:
- SwiftUI intercepts keyboard events before they reach embedded AppKit views
- Standard `makeFirstResponder()` succeeds but events still go to SwiftUI
- Ghostty (another terminal app) solved this same problem

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                    TerminalFocusManager                         │
│                        (singleton)                              │
├─────────────────────────────────────────────────────────────────┤
│  • Tracks focused terminal across windows                       │
│  • Uses NotificationCenter (not window.delegate)                │
│  • Retry-based focus with exponential backoff (max 2s)          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   TerminalViewController                        │
├─────────────────────────────────────────────────────────────────┤
│  Local Event Monitor:                                           │
│  • Intercepts keyDown/keyUp/flagsChanged                        │
│  • Forwards to terminal, returns nil to consume                 │
│  • Prevents SwiftUI from handling keyboard                      │
├─────────────────────────────────────────────────────────────────┤
│  Global Click Monitor:                                          │
│  • Catches clicks when app is not active                        │
│  • Activates app + window when clicked from other apps          │
└─────────────────────────────────────────────────────────────────┘
```

**Files**:
- `Sources/Controllers/TerminalWindowController.swift` - Focus manager
- `Sources/Views/Components/TerminalView.swift` - Event monitors

**Documentation**: `docs/development/solution-terminal-keyboard.md`

---

## Data Flow

### Adding a Repository

```
User clicks "Add Repository"
         │
         ▼
    FileImporter (folder picker)
         │
         ▼
    Validate .git exists
         │
         ▼
    Create Repo model
         │
         ▼
    Insert into ModelContext
         │
         ▼
    @Query updates SidebarView
```

### Creating a Workspace

```
User right-clicks repo → "New Workspace..."
         │
         ▼
    NewWorkspaceSheet (enter name)
         │
         ▼
    WorkspaceService.createWorkspace()
         │
         ├─→ Create directory in workspaces root
         │
         ├─→ Copy repo with `ditto`
         │
         ├─→ Create git branch (optional)
         │
         ├─→ Run setup.sh if exists (show output in terminal)
         │
         ▼
    Create Workspace model
         │
         ▼
    Insert into ModelContext
         │
         ▼
    Select new workspace
         │
         ▼
    Terminal recreates in new directory
```

### Closing/Archiving a Workspace

```
User archives or deletes workspace
         │
         ▼
    Run archive.sh if exists (show output)
         │
         ▼
    Update workspace status or delete
         │
         ▼
    Optionally delete files from disk
```

### Selecting a Workspace

```
User clicks workspace in sidebar
         │
         ▼
    Selection binding updates
         │
         ▼
    ContentView passes workspace to TerminalContainerView
         │
         ▼
    TerminalView.id changes → View recreated
         │
         ▼
    New LocalProcessTerminalView starts in workspace.workspaceURL
         │
         ▼
    RightPaneView refreshes file tree and git status
```

---

## File System Layout

```
~/workspaces/                              ← Default (configurable in Settings)
├── my-project/
│   ├── feature-auth/                      ← Workspace directory
│   │   ├── .git/
│   │   ├── src/
│   │   ├── setup.sh                       ← Lifecycle hook (optional)
│   │   ├── archive.sh                     ← Lifecycle hook (optional)
│   │   └── ...
│   └── experiment-ui/                     ← Another workspace
│       └── ...
└── other-repo/
    └── bugfix-123/

~/Library/Application Support/WorkspaceManager/
└── WorkspaceManager.sqlite                ← SwiftData store (automatic)
```

**Configuration**: Workspace root is configurable in app settings. Default: `~/workspaces`

**Note**: Source repos stay in their original locations. Workspaces are copies.

---

## Workspace Lifecycle Hooks

Repos can include optional shell scripts that run at specific lifecycle points:

### setup.sh (Post-Creation)

Runs after workspace is copied from repo. Use for:
- Installing dependencies (`npm install`, `bundle install`)
- Setting up environment files (`.env` from `.env.example`)
- Initializing databases
- Any project-specific setup

```bash
#!/bin/bash
# Example setup.sh
npm install
cp .env.example .env
echo "Workspace ready!"
```

### archive.sh (Pre-Archive/Close)

Runs when workspace is archived or closed. Use for:
- Cleaning build artifacts
- Stopping background processes
- Backing up local data
- Any cleanup tasks

```bash
#!/bin/bash
# Example archive.sh
npm run clean
docker-compose down
echo "Workspace archived"
```

**Execution**:
- Scripts run in workspace directory
- Scripts run with user's shell environment
- Stdout/stderr captured and shown in terminal
- Non-zero exit doesn't block operation (warning shown)
- Scripts are optional — missing scripts are silently skipped

---

## Threading Model

| Operation | Thread | Mechanism |
|-----------|--------|-----------|
| UI updates | Main | SwiftUI automatic |
| SwiftData queries | Main | @Query macro |
| SwiftData writes | Main | modelContext.insert() |
| Git operations | Background | Actor isolation |
| File operations | Background | Actor isolation |
| Terminal I/O | SwiftTerm managed | PTY + dispatch |

**Rule**: All `GitService` and `WorkspaceService` calls use `await`.

---

## Error Handling Strategy

1. **Services throw errors** — Let them bubble up
2. **Views catch and display** — Using alert modifier
3. **Non-fatal errors** — Log and continue (e.g., can't get remote URL)
4. **Fatal errors** — Show alert, don't crash

```swift
// In view
.alert("Error", isPresented: $showError) {
    Button("OK") { }
} message: {
    Text(errorMessage)
}

// In action
do {
    try await WorkspaceService.shared.createWorkspace(...)
} catch {
    errorMessage = error.localizedDescription
    showError = true
}
```

---

## Testing Strategy

### Unit Tests (Future)
- GitService parsing
- WorkspaceService file operations
- Model relationships

### Manual Testing (MVP)
1. Add repo → appears in sidebar
2. Create workspace → directory created, appears in sidebar
3. Select workspace → terminal opens in correct directory
4. Run commands → output appears
5. Modify files → git status updates
6. Quit and relaunch → data persists

### Edge Cases to Test
- Repo without .git directory
- Repo with no remote
- Very large repos
- Repos with special characters in path
- Workspace name conflicts
- Disk full during copy
- Permission denied errors
