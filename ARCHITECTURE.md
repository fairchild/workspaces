# Workspace Manager — Architecture

## Design Principles

1. **Terminal-first**: The embedded terminal is the primary experience, not a code editor
2. **Native feel**: Use AppKit/SwiftUI patterns, feel like a Mac app
3. **Simple data model**: Repos → Workspaces → Files, nothing more
4. **Offline-first**: Works without internet (git remotes optional)
5. **Non-destructive**: Never delete user's source repos

---

## Related Web Surfaces

This document covers the macOS app. Two separate Next.js apps in this repo relate to it differently — see `AGENTS.md` § "Two Web Apps" for the full charter:

- **`web-next/`** is the active sessions-first web app, deployed at `folio.cloudcompute.com`. The macOS app also embeds it locally over loopback HTTP — spawn, readiness, and token handoff are `WebNextServerService`; the in-app surface is `EmbeddedWebNextDetailView` — per the contract in `web-next/docs/decisions/embedded-native-contract.md`.
- **`web/`** is the original dashboard, in maintenance mode since #754 (no cutover); it still serves GitHub webhook ingestion.

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
│  │ repo1  │  │  │ (GhosttyKit surface)   │  │  │                 │  │
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
│   GitService    │  WorkspaceService    │    Backends                │
│   (actor)       │  (actor)             │                            │
│                 │                      │                            │
│  • getStatus()  │  • createWorkspace() │    LocalBackend            │
│  • getFileTree()│  • deleteWorkspace() │    DaytonaBackend          │
│  • getBranch()  │  • createWorktree()  │                            │
└─────────────────┴──────────────────────┴────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         SwiftData Layer                             │
├─────────────────────────────────────────────────────────────────────┤
│  ModelContainer                                                     │
│  ├── Repo (id, name, localPath, remoteURL, addedAt)                 │
│  └── Workspace (id, name, path, sourceRepo, statusRaw, gitBranch)   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Key Technical Decisions

### 1. SwiftUI + AppKit Hybrid

**Decision**: Use SwiftUI for views, AppKit for app/window lifecycle.

**Rationale**:
- SwiftUI's `NavigationSplitView` works well for three-column layouts
- AppKit gives better control over window management
- GhosttyKit provides `ghostty_surface_t` embedded in a custom `NSView`

**Pattern**:
```swift
// App entry uses SwiftUI
@main
struct WorkspaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // ...
}

// Terminal wrapped for SwiftUI
struct GhosttyTerminalRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> GhosttySurfaceView { ... }
}
```

### 2. GhosttyKit for Terminal

**Decision**: Use GhosttyKit (`libghostty`) for embedded terminal rendering and input.

**Rationale**:
- Production-proven terminal core from Ghostty
- GPU-backed renderer and high-performance parser
- C embedding API allows direct AppKit integration in `GhosttySurfaceView`
- Single terminal engine across app/runtime callbacks and surface lifecycle

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

**Decision**: Define `RemoteBackendProtocol`, ship with `LocalBackend` and `DaytonaBackend`.

**Rationale**:
- Local backend covers the common case (direct filesystem access)
- Daytona provides remote cloud sandboxes via SSH
- Protocol abstraction allows adding backends without changing app code

**Current backends**:
- `LocalBackend` — direct filesystem, no isolation
- `DaytonaBackend` — remote VM sandboxes via Daytona API

**Protocol**:
```swift
protocol RemoteBackendProtocol: Sendable {
    var identifier: String { get }
    func isAvailable() async -> Bool
    func createSandbox(name: String, cloneURL: String?) async throws -> RemoteSandboxInfo
    func stopSandbox(sandboxId: String) async throws
    func deleteSandbox(sandboxId: String) async throws
    // ...
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
│                     GhosttySurfaceView                          │
├─────────────────────────────────────────────────────────────────┤
│  NSView overrides: key/mouse/scroll/focus                       │
│  • Sends input directly to ghostty_surface_* APIs               │
│  • Updates scale + framebuffer size for backing changes         │
│  • Uses minimal local monitor (.keyUp, .leftMouseDown)          │
└─────────────────────────────────────────────────────────────────┘
```

**Files**:
- `Sources/WorkspaceManager/Controllers/TerminalWindowController.swift` - Focus manager
- `Sources/WorkspaceManager/Views/Components/TerminalView.swift` - Event monitors

**Documentation**: `docs/development/solution-terminal-keyboard.md`
and `docs/development/libghostty-integration.md`

### 8. Real-Time Notifications via Cloudflare Worker

**Decision**: Relay GitHub webhooks to connected clients over WebSocket via a Cloudflare Worker with Durable Objects.

**Rationale**:
- GitHub webhooks need a public endpoint — Cloudflare Workers provide this with zero server management
- Durable Objects give per-repo state (SQLite event storage, WebSocket sessions) without external databases
- Hibernation API means idle repos cost nothing
- WebSocket provides instant delivery without polling

**Architecture**:
```
GitHub webhook ──▶ Worker ──▶ Durable Object (per owner/repo)
                                  │
                              ┌───┴───┐
                              │SQLite │  ← 7-day event retention
                              └───┬───┘
                                  │
                              WebSocket broadcast
                                  │
macOS App ◀───────────────────────┘
  NotificationCoordinator (auth + stream lifecycle)
  └── EventStreamService (WebSocket + reconnect)
```

**Auth**: GitHub Device Flow → token → JWT (8h, HMAC-SHA256). JWT `orgs` claim prevents IDOR on WebSocket connect. JWT is silently refreshed 15 min before expiry; on failure the user is signed out.

**Files**: `infra/cloudflare-webhook-relay/`, `NotificationCoordinator.swift`, `EventStreamService.swift`

**Documentation**: `docs/development/notifications.md`

### 9. Host Terminal Surface Memory Policy (Refinement Gate)

**Decision**: Keep terminal surfaces unbounded for now (no inactive-surface LRU cap yet).

**Rationale**:
- Preserves deterministic session restore semantics (prompt/history stays instantly reusable).
- Current usage scale is small enough that forcing surface eviction is more likely to regress UX than prevent real memory issues.
- The implementation now logs when live surfaces reach a revisit threshold, so pressure can be detected early.

**Revisit triggers**:
- Sustained usage reaches `>= 24` live host surfaces (warning log emitted).
- Instruments sessions show memory pressure, hang risk, or unacceptable launch/switch regressions attributable to retained surfaces.
- User-reported slowdowns tied to large numbers of inactive sessions.

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
         ├─→ Create git worktree and workspace branch
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
    New GhosttySurfaceView starts in workspace.workspaceURL
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
| Terminal I/O | GhosttyKit managed | Surface + runtime callbacks |

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

Uses **Swift Testing** (`@Suite`, `@Test`, `#expect`). Test suites cover:

- `GitServiceTests` — git status parsing, branch detection, file tree
- `WorkspaceServiceTests` — workspace creation, lifecycle hooks, deletion
- `ModelsTests` — Codable roundtrips, data contracts
- `LocalBackendTests` — filesystem operations
- `HostTerminalSessionCoordinatorTests` — terminal session identity
- `HostTerminalDefaultsTests` — terminal preference persistence
- `ProcessRunnerTests` — shell command execution
- `RepositoryDiscoveryTests` — repo scanning and validation
- `GitHubDeviceAuthTests` — device flow auth with mock HTTP
- `NotificationSessionServiceTests` — JWT session exchange with mock HTTP
- `WebhookEventTests` — Codable roundtrips for event model
- `NotificationCoordinatorTests` — JWT parsing, remote URL parsing, coordinator lifecycle
