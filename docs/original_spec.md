# Workspace Manager — Component Specifications

## 1. Data Models

### Repo

Represents a git repository added by the user.

```swift
@Model
final class Repo {
    var id: UUID                    // Unique identifier
    var name: String                // Display name (usually folder name)
    var localPath: String           // Absolute path to repo on disk
    var remoteURL: String?          // Git remote origin URL (optional)
    var addedAt: Date               // When user added this repo
    
    @Relationship(deleteRule: .cascade, inverse: \Workspace.sourceRepo)
    var workspaces: [Workspace]     // Workspaces created from this repo
    
    // Computed
    var localURL: URL { URL(fileURLWithPath: localPath) }
}
```

**Validation**:
- `localPath` must exist and be a directory
- `localPath` must contain `.git` subdirectory
- `name` defaults to last path component

### Workspace

Represents an isolated copy of a repo for development.

```swift
@Model
final class Workspace {
    var id: UUID                    // Unique identifier
    var name: String                // User-provided name
    var path: String                // Absolute path to workspace directory
    var sourceRepo: Repo?           // Parent repo (relationship)
    var createdAt: Date             // Creation timestamp
    var lastAccessedAt: Date        // Last time user selected this
    var statusRaw: String           // "active" or "archived"
    var gitBranch: String?          // Current git branch name
    var backendIdentifier: String   // Isolation backend ("local", "docker", etc.)
    
    // Computed
    var workspaceURL: URL { URL(fileURLWithPath: path) }
    var status: WorkspaceStatus { get/set via statusRaw }
}

enum WorkspaceStatus: String {
    case active
    case archived
}
```

**Behavior**:
- Deleting workspace can optionally delete files
- `lastAccessedAt` updates on selection
- Archived workspaces hidden by default (future feature)

### FileChange

Runtime model for git status (not persisted).

```swift
struct FileChange: Identifiable, Hashable {
    var id: String { path }
    let path: String                // Relative path from workspace root
    let status: GitStatus           // Type of change
}

enum GitStatus: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case untracked = "?"
    case renamed = "R"
    
    var icon: String { ... }        // SF Symbol name
    var color: Color { ... }        // SwiftUI color
}
```

### FileNode

Runtime model for file tree (not persisted).

```swift
struct FileNode: Identifiable, Hashable {
    let id: UUID
    let name: String                // File or folder name
    let path: String                // Relative path from workspace root
    let isDirectory: Bool
    var children: [FileNode]?       // Nil for files, array for directories
    
    var icon: String { ... }        // SF Symbol based on file extension
}
```

---

## 2. Views

### ContentView

Main window content with three-column layout.

**Structure**:
```swift
NavigationSplitView {
    SidebarView(...)
} detail: {
    HSplitView {
        TerminalContainerView(workspace: selectedWorkspace)
        if isRightPaneVisible {
            RightPaneView(workspace: selectedWorkspace)
        }
    }
}
```

**State**:
- `selectedWorkspace: Workspace?` — Currently selected workspace
- `isRightPaneVisible: Bool` — Toggle for right pane
- `columnVisibility: NavigationSplitViewVisibility`

**Toolbar**:
- Toggle right pane button (Cmd+0)

### SidebarView

Left sidebar with repos and workspaces.

**Sections**:
1. **Repositories** — List of added repos
2. **Workspaces** — List of all workspaces (sorted by lastAccessedAt)

**Interactions**:
- Click repo: No action (just informational)
- Click workspace: Select it, update terminal
- Right-click repo: Context menu with "New Workspace..."
- Right-click workspace: Context menu with actions

**Footer**:
- "Add Repository" button

**Context Menus**:

Repo:
- New Workspace...
- Reveal in Finder
- Remove from List (doesn't delete files)

Workspace:
- Open in New Window (future)
- Reveal in Finder
- Archive / Unarchive
- Delete Workspace

### TerminalContainerView

Wrapper around terminal with header bar.

**Structure**:
```
┌────────────────────────────────────────┐
│ 🖥️  /path/to/workspace        [↻]     │  ← Header bar
├────────────────────────────────────────┤
│                                        │
│  GhosttyTerminalRepresentable          │  ← GhosttyKit surface
│                                        │
└────────────────────────────────────────┘
```

**Header Bar**:
- Terminal icon
- Current path (truncated from left)
- Restart button

**Behavior**:
- Restart button recreates terminal
- Terminal fills available space

### TerminalView

NSViewRepresentable wrapper for `GhosttySurfaceView`.

**Configuration**:
- Font size: 13pt (surface config)
- Shell: User's default shell (`$SHELL`) with `--login`
- Working directory: Workspace path
- Runtime owner: `GhosttyAppManager` singleton (`ghostty_app_t`)

**Environment Variables**:
```
TERM=xterm-256color
COLORTERM=truecolor
LANG=en_US.UTF-8
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH
```

**Lifecycle**:
- Created when workspace selected
- Destroyed when workspace changes (use `.id(workspace.id)`)
- Process termination callback routed from Ghostty close-surface callback
- Focus and app activation synced via `TerminalFocusManager` + `GhosttyAppManager`

Reference: `docs/development/libghostty-integration.md`

### RightPaneView

Collapsible right pane with tabbed content.

**Structure**:
```
┌─────────────────────────┐
│  [Files]  [Changes •3]  │  ← Tab bar (segmented)
├─────────────────────────┤
│                         │
│  FileTreeView           │  ← Tab content
│       or                │
│  ChangedFilesView       │
│                         │
├─────────────────────────┤
│  Updated 2m ago    [↻]  │  ← Footer
└─────────────────────────┘
```

**Tabs**:
1. **Files** — Directory tree
2. **Changes** — Git status with badge showing count

**State**:
- `selectedTab: Tab` — Current tab
- `fileTree: FileNode?` — Loaded tree
- `changedFiles: [FileChange]` — Git status
- `isLoading: Bool` — Loading indicator
- `lastRefresh: Date` — For "Updated X ago"

**Refresh**:
- Automatic on workspace selection
- Manual via refresh button
- Show loading indicator during refresh

### FileTreeView

Collapsible directory tree.

**Implementation**:
```swift
List {
    FileNodeView(node: rootNode, level: 0)
}
```

**FileNodeView**:
- Directories use `DisclosureGroup`
- Files are simple rows
- Icons based on file type
- Click does nothing (future: open in editor)

**Excluded**:
- Hidden files (starting with `.`)
- `node_modules`
- `.git`
- `build`, `DerivedData`, etc.

### ChangedFilesView

List of modified files from git status.

**Row Layout**:
```
[M] src/components/Button.swift
[A] src/utils/helpers.swift
[?] test.txt
```

**Empty State**:
```
✓ No Changes
Working directory is clean
```

**Behavior**:
- Click does nothing (future: show diff)
- Status icon colored by type

### NewWorkspaceSheet

Modal for creating a new workspace.

**Structure**:
```
┌────────────────────────────────────────┐
│           📁+ New Workspace            │
│            from my-project             │
├────────────────────────────────────────┤
│                                        │
│  Workspace Name: [_______________]     │
│                                        │
│  A copy of the repository will be      │
│  created in a new directory.           │
│                                        │
│  ⓘ setup.sh will run after creation   │  ← Show if script exists
│                                        │
├────────────────────────────────────────┤
│              [Cancel]  [Create]        │
└────────────────────────────────────────┘
```

**Validation**:
- Name required
- Name sanitized for filesystem (no /, \, :, etc.)

**Behavior**:
- Create button disabled until valid
- Shows loading while creating
- Shows setup.sh output in terminal after creation
- Dismisses and selects workspace on success
- Shows error on failure

### SettingsView

App settings (Cmd+,).

**Structure**:
```
┌─────────────────────────────────────────────────────────┐
│  General                                                │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  WorkSpaces Location                                    │
│  ┌─────────────────────────────────────────┐            │
│  │ ~/workspaces                        [📁]│            │
│  └─────────────────────────────────────────┘            │
│  Where new workspaces are created.                      │
│                                                         │
│  ─────────────────────────────────────────────────────  │
│                                                         │
│  Terminal                                               │
│  Shell: [System Default ▼]                              │
│  Font Size: [13]                                        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Settings Stored**:
- `workspacesRoot: URL` — Default: `~/workspaces`
- `terminalFontSize: Int` — Default: 13 (future)
- `shell: String?` — Default: nil (use $SHELL)

**Implementation**:
```swift
struct SettingsView: View {
    @AppStorage("workspacesRoot") private var workspacesRootPath: String = 
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspaces").path
    
    var body: some View {
        Form {
            Section("General") {
                HStack {
                    TextField("WorkSpaces Location", text: $workspacesRootPath)
                    Button("Choose...") {
                        // Open folder picker
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

---

## 3. Services

### GitService

Actor for git operations.

**Methods**:

```swift
actor GitService {
    static let shared = GitService()
    
    /// Get list of changed files
    func getStatus(at path: URL) async throws -> [FileChange]
    
    /// Build file tree for directory
    func getFileTree(at path: URL, maxDepth: Int = 4) async throws -> FileNode
    
    /// Get current branch name
    func getCurrentBranch(at path: URL) async throws -> String?
    
    /// Get remote origin URL
    func getRemoteURL(at path: URL) async throws -> String?
    
    /// Create new branch
    func createBranch(_ name: String, at path: URL) async throws
    
    /// Checkout existing branch
    func checkoutBranch(_ name: String, at path: URL) async throws
}
```

**Git Status Parsing**:

Input: `git status --porcelain=v1`
```
 M src/file1.swift
A  src/file2.swift
?? untracked.txt
```

Output: Array of `FileChange`

**File Tree Building**:
- Use `FileManager.contentsOfDirectory`
- Recursively build tree up to maxDepth
- Sort: directories first, then alphabetically
- Exclude: hidden, node_modules, .git, build dirs

### WorkspaceService

Actor for workspace management.

**Methods**:

```swift
actor WorkspaceService {
    static let shared = WorkspaceService()
    
    /// Root directory for all workspaces (configurable, default ~/workspaces)
    var workspacesRoot: URL { 
        if let custom = UserDefaults.standard.url(forKey: "workspacesRoot") {
            return custom
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspaces")
    }
    
    /// Set custom workspaces root directory
    func setWorkspacesRoot(_ url: URL) {
        UserDefaults.standard.set(url, forKey: "workspacesRoot")
    }
    
    /// Create a new workspace from a repo
    func createWorkspace(from repo: Repo, name: String) async throws -> Workspace
    
    /// Run archive.sh and optionally delete workspace
    func archiveWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws
    
    /// Delete a workspace (runs archive.sh first if exists)
    func deleteWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws
    
    /// Get disk usage of a workspace
    func getWorkspaceSize(_ workspace: Workspace) async throws -> Int64
    
    /// Run a lifecycle script in workspace directory
    func runLifecycleScript(_ script: String, in workspace: Workspace) async throws -> ProcessResult
}
```

**Workspace Creation Steps**:
1. Sanitize name for filesystem
2. Create directory path: `{workspacesRoot}/{repo.name}/{sanitizedName}`
3. Check doesn't already exist
4. Create git worktree at that path with branch `workspace/{name}`
5. Fail clearly and clean up if branch or worktree creation fails
6. **Run `setup.sh` if exists** (capture output, show in terminal)
7. Return Workspace model (caller inserts into SwiftData)

**Workspace Archive/Delete Steps**:
1. **Run `archive.sh` if exists** (capture output, show in terminal)
2. Update status to archived OR delete from SwiftData
3. Optionally remove the workspace directory/worktree from disk

**Lifecycle Script Execution**:
```swift
func runLifecycleScript(_ scriptName: String, in workspace: Workspace) async throws -> ProcessResult {
    let scriptPath = workspace.workspaceURL.appendingPathComponent(scriptName)
    
    // Check if script exists
    guard FileManager.default.fileExists(atPath: scriptPath.path) else {
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")  // Silent skip
    }
    
    // Make executable if needed
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], 
        ofItemAtPath: scriptPath.path
    )
    
    // Run script
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptPath.path]
    process.currentDirectoryURL = workspace.workspaceURL
    process.environment = ProcessInfo.processInfo.environment
    
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    
    try process.run()
    process.waitUntilExit()
    
    return ProcessResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}
```

---

## 4. Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+0 | Toggle right pane |
| Cmd+1 | Focus sidebar |
| Cmd+Shift+T | New workspace (from selected repo) |
| Cmd+R | Refresh right pane |
| Cmd+, | Open settings (future) |

**Implementation**:
```swift
.keyboardShortcut("0", modifiers: .command)
```

---

## 5. Error Messages

| Scenario | Message |
|----------|---------|
| Not a git repo | "The selected folder is not a git repository" |
| Workspace exists | "A workspace named 'X' already exists" |
| Copy failed | "Failed to create workspace: {reason}" |
| Git not found | "Git is not installed or not in PATH" |
| Permission denied | "Permission denied: {path}" |

---

## 6. Empty States

### No Repositories
```
📁 No Repositories

Add a git repository to get started.

[Add Repository]
```

### No Workspaces
```
🖥️ No Workspace Selected

Add a repository and create a workspace
to get started.

1. Add a git repository from your Mac
2. Fork it to create an isolated workspace
3. Run Claude Code in the embedded terminal
```

### No Changes
```
✓ No Changes

Working directory is clean
```

### Loading
```
[Spinner] Loading...
```

---

## 7. Context Menu Specs

### Repo Context Menu
```
New Workspace...
─────────────────
Reveal in Finder
Copy Path
─────────────────
Remove from List    (doesn't delete repo)
```

### Workspace Context Menu
```
Open in New Window  (future)
Reveal in Finder
Copy Path
─────────────────
Archive            (or "Unarchive" if archived)
─────────────────
Delete Workspace    (with confirmation)
```

### Confirmation Dialog (Delete Workspace)
```
Delete "feature-auth"?

This will remove the workspace from the list.

☐ Also delete files from disk

[Cancel]  [Delete]
```
