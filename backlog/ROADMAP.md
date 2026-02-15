---
status: in-progress
category: plan
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# AI Coding Workspace Manager — MVP Roadmap

**Vision**: A Mac-native app for managing AI coding sessions. Add repos, fork them into isolated workspaces, run Claude Code (or similar) in an embedded terminal, and track file changes—all without context-switching to Finder or a separate terminal.

---

## Current Locked Direction (2026-02-14)

For the VZ/Tahoe implementation track (`M2`-`M6`), `/Users/fairchild/code/workspaces/backlog/vz-tahoe-execution-brief-plan.md` is the source of truth.

Execution priority is:

1. Complete the **Refinement Gate (Before M2)** in this roadmap.
2. Resume the execution brief milestones starting at `M2`.

### Product Defaults

- App launch opens a live host terminal in `~/code` by default (fallback to `$HOME/code`, then `$HOME`).
- Main terminal stays host-pinned by default.
- Sidebar clicks are explicit terminal actions:
  - Host Portfolio row returns to the default host session.
  - Repo/workspace rows open or resume persistent host sessions in those directories.
- Users can spawn additional regular host terminals from the host context.
- Sidebar shows live session indicators for repos with active terminals.

### VM Lifecycle Scope

- No VM creation or startup at app launch.
- VM creation/start is triggered when creating a new workspace configured for `vzLinuxTahoe`.
- Existing tracked workspaces remain `local` (no auto-migration).

### Backend + Platform Scope

- Native `Virtualization.framework` backend first (`vzLinuxTahoe`).
- VZ backend support target: macOS 26+ (Tahoe), Apple Silicon only.
- New workspaces default to VZ backend only on supported hosts; fallback remains local backend.

### Execution Routing Defaults

- VZ workspaces: run commands in VM by default.
- Host build/test routing in `auto` mode for:
  - `xcodebuild`
  - `swift build`
  - `swift test`
- Explicit overrides:
  - `--host` forces host execution.
  - `--vm` forces VM execution.

### Security Defaults

- Workspace mount in VM is RW virtiofs.
- Per-workspace vmnet logical network with NAT default.
- Outbound egress is unrestricted in phase 1.
- Any non-workspace extra mounts require an external allowlist outside the repo/workspace.

### Best Implementation Order

1. [x] Host-terminal-first foundation and persistent session UX.
2. [ ] Refinement gate: quality hardening and performance baselining for current feature set.
3. [ ] Backend abstraction/registry in core while preserving `LocalBackend`.
4. [ ] `VZTahoeBackend` implementation (runtime checks, VM lifecycle, vmnet, SSH executor, allowlist).
5. [ ] New-workspace flow integration to create/start VM only for VZ workspaces.
6. [ ] CLI backend-aware routing (`auto`, `--host`, `--vm`) plus VM lifecycle commands.
7. [ ] Tests, docs, fallback hardening, and validation.

### Performance Backlog (Fast-Path Follow-ups)

- [ ] Add production signposts around launch, repo hydration, and repo-click-to-focus latency.
- [ ] Run Instruments baselines (Time Profiler + SwiftUI + Hangs) and check in a short perf report.
- [ ] Add optional session/surface cap policy (LRU for inactive repo sessions) if memory pressure appears.
- [ ] Re-introduce remote URL metadata in a background/idle pipeline (not launch-critical path).

---

## Refinement Gate (Before M2)

The next cycle prioritizes implementation quality for shipped behavior before expanding the feature set.

### Objectives

- Make session behavior deterministic under fast click-switching between repos and workspaces.
- Keep launch and interaction latency consistently fast on real `~/code` portfolios.
- Ensure release workflow reliability stays boring and repeatable.
- Align product docs and stories with the behavior users are actually testing.

### Exit Criteria

- [ ] `swift test` remains green with added regression coverage for session focus and reuse semantics.
- [ ] A short perf report is checked in with baseline numbers for:
  - launch-to-first-prompt
  - repo hydration
  - repo-click-to-focused-terminal
- [ ] No open crash/repro defects around workspace selection and session switching.
- [ ] Release workflow passes end-to-end from `main` (signed + notarized DMG published).
- [ ] Product docs (`docs/product_overview.md`, `docs/user-stories.md`) reflect implemented UX.

### Planned Work Items

- [ ] Add instrumentation signposts around launch, sidebar selection handling, and terminal focus handoff.
- [ ] Add focused regression tests for session reuse + focus restoration behavior.
- [ ] Add a lightweight memory guardrail decision: either cap inactive surfaces (LRU) or document why unbounded is acceptable today.
- [ ] Tighten release docs/scripts around Apple credential troubleshooting and idempotent setup.
- [ ] Capture usage findings and feed them into post-refinement prioritization for M2.

---

> Note: detailed "Phase 1-4" sections below are retained as historical implementation context.
> Current execution priority is defined by the locked direction above plus the refinement gate.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  App Window                                                             │
├────────────┬────────────────────────────────────────────┬───────────────┤
│            │                                            │               │
│  Sidebar   │         Main Terminal Panel                │  Right Pane   │
│            │         (SwiftTerm)                        │  (collapsible)│
│  ┌──────┐  │                                            │               │
│  │Repos │  │  $ claude                                  │  ┌─────────┐  │
│  ├──────┤  │  ╭─────────────────────────────────────╮   │  │Files│Δ  │  │
│  │ repo1│  │  │ Claude Code                         │   │  ├─────────┤  │
│  │ repo2│  │  │                                     │   │  │ src/    │  │
│  ├──────┤  │  │ > Working on your request...        │   │  │ lib/    │  │
│  │Worksp│  │  │                                     │   │  │ test/   │  │
│  ├──────┤  │  ╰─────────────────────────────────────╯   │  │         │  │
│  │ ws-1 │  │                                            │  │         │  │
│  │ ws-2 │  │                                            │  │         │  │
│  │ ws-3 │  │                                            │  │         │  │
│  └──────┘  │                                            │  └─────────┘  │
│            │                                            │               │
│ [+ Add]    │                                            │  [◀ collapse] │
└────────────┴────────────────────────────────────────────┴───────────────┘
```

**Tech Stack**:

| Component | Choice | Why |
|-----------|--------|-----|
| App lifecycle | AppKit (`NSApplication`) | Window management, multiple workspaces |
| Layout shell | SwiftUI `NavigationSplitView` | Modern, works well for this layout |
| Sidebar | SwiftUI `List` with sections | Simple hierarchy, not 10k+ items |
| Terminal | **GhosttyKit** `GhosttySurfaceView` | Fast, native terminal surfaces with persistent session support |
| File tree | SwiftUI `List` + `DisclosureGroup` | Adequate for browsing (not editing) |
| Changed files | SwiftUI `List` + git status parsing | Simple list |
| Persistence | SwiftData (or JSON file for MVP) | Native, simple |
| Distribution | Direct + notarization | Required for shell execution |

---

## Data Model

```swift
// Core entities

@Model
class Repo {
    var id: UUID
    var name: String
    var localPath: URL          // /Users/mf/code/some-repo
    var remoteURL: String?      // git@github.com:user/repo.git
    var addedAt: Date
    var workspaces: [Workspace]
}

@Model
class Workspace {
    var id: UUID
    var name: String            // "feature-auth", "experiment-1"
    var path: URL               // /Users/mf/.workspaces/repo-name/feature-auth
    var sourceRepo: Repo
    var createdAt: Date
    var lastAccessedAt: Date
    var status: WorkspaceStatus // .active, .archived
    var gitBranch: String?
}

enum WorkspaceStatus: String, Codable {
    case active, archived
}

// Runtime state (not persisted)
@Observable
class WorkspaceSession {
    var workspace: Workspace
    var terminal: LocalProcessTerminalView?
    var changedFiles: [FileChange] = []
    var isTerminalRunning: Bool = false
}

struct FileChange: Identifiable {
    var id: String { path }
    var path: String
    var status: GitStatus       // .modified, .added, .deleted, .untracked
}
```

---

## Phase 1: Foundation (Week 1-2)

**Goal**: App shell with sidebar, terminal that runs, basic persistence.

### 1.1 Project Setup

- [x] Create new Xcode project (macOS App, SwiftUI lifecycle initially)
- [x] Add SwiftTerm via SPM: `https://github.com/migueldeicaza/SwiftTerm`
- [x] Set minimum deployment: macOS 14.0
- [x] Configure entitlements (non-sandboxed)
- [x] Set up basic app structure:

```
Sources/
├── App/
│   ├── WorkspaceManagerApp.swift
│   └── AppDelegate.swift        // For AppKit lifecycle hooks
├── Models/
│   ├── Repo.swift
│   ├── Workspace.swift
│   └── DataStore.swift
├── Views/
│   ├── MainWindow/
│   │   ├── ContentView.swift    // NavigationSplitView shell
│   │   ├── SidebarView.swift
│   │   ├── TerminalContainerView.swift
│   │   └── RightPaneView.swift
│   └── Components/
│       ├── TerminalView.swift   // NSViewRepresentable wrapper
│       └── FileTreeView.swift
└── Services/
    ├── GitService.swift
    ├── WorkspaceService.swift
    └── ProcessService.swift
```

### 1.2 SwiftTerm Integration

```swift
// Views/Components/TerminalView.swift
import SwiftUI
import SwiftTerm

struct TerminalView: NSViewRepresentable {
    let workingDirectory: URL
    var onProcessExit: (() -> Void)?
    
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        
        // Configure appearance
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.installColors(theme: .defaultDark)
        
        // Start shell in workspace directory
        terminal.startProcess(
            executable: "/bin/zsh",
            args: [],
            environment: makeEnvironment(),
            execName: "zsh"
        )
        
        // Change to working directory
        terminal.send(txt: "cd \"\(workingDirectory.path)\" && clear\n")
        
        return terminal
    }
    
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
    
    private func makeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Ensure Claude Code / common tools are in PATH
        if let path = env["PATH"] {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + path
        }
        return env
    }
}
```

### 1.3 Basic Layout Shell

```swift
// Views/MainWindow/ContentView.swift
struct ContentView: View {
    @State private var selectedRepo: Repo?
    @State private var selectedWorkspace: Workspace?
    @State private var isRightPaneVisible = true
    
    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedRepo: $selectedRepo,
                selectedWorkspace: $selectedWorkspace
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            HSplitView {
                // Main terminal
                if let workspace = selectedWorkspace {
                    TerminalContainerView(workspace: workspace)
                } else {
                    EmptyStateView()
                }
                
                // Collapsible right pane
                if isRightPaneVisible, let workspace = selectedWorkspace {
                    RightPaneView(workspace: workspace)
                        .frame(minWidth: 250, maxWidth: 400)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        withAnimation { isRightPaneVisible.toggle() }
                    } label: {
                        Image(systemName: isRightPaneVisible 
                            ? "sidebar.trailing" 
                            : "sidebar.trailing")
                    }
                }
            }
        }
    }
}
```

### 1.4 Deliverables

- [x] App launches with three-column layout
- [x] Terminal runs zsh in a hardcoded directory
- [x] Can type commands, see output
- [x] Sidebar shows placeholder repos/workspaces

---

## Phase 2: Repo & Workspace Management (Week 3-4)

**Goal**: Add repos, create workspaces (directory copies), persist state.

### 2.1 Add Repo Flow

```swift
// Services/WorkspaceService.swift
class WorkspaceService {
    static let shared = WorkspaceService()
    
    private let workspacesRoot: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, 
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("WorkspaceManager")
            .appendingPathComponent("workspaces")
    }()
    
    func addRepo(from url: URL) async throws -> Repo {
        // Validate it's a git repo
        let gitDir = url.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else {
            throw WorkspaceError.notAGitRepo
        }
        
        let repo = Repo(
            id: UUID(),
            name: url.lastPathComponent,
            localPath: url,
            addedAt: Date()
        )
        
        // Get remote URL if available
        repo.remoteURL = try? await GitService.shared.getRemoteURL(at: url)
        
        return repo
    }
    
    func createWorkspace(from repo: Repo, name: String) async throws -> Workspace {
        let workspaceDir = workspacesRoot
            .appendingPathComponent(repo.name)
            .appendingPathComponent(name)
        
        // Copy repo to workspace directory
        try FileManager.default.createDirectory(
            at: workspaceDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        // Use git worktree OR simple copy
        // Option A: Git worktree (shares .git, more efficient)
        // Option B: Full copy (simpler, fully isolated)
        try await copyRepo(from: repo.localPath, to: workspaceDir)
        
        // Create new branch for this workspace
        let branchName = "workspace/\(name)"
        try await GitService.shared.createBranch(branchName, at: workspaceDir)
        
        return Workspace(
            id: UUID(),
            name: name,
            path: workspaceDir,
            sourceRepo: repo,
            createdAt: Date(),
            lastAccessedAt: Date(),
            status: .active,
            gitBranch: branchName
        )
    }
    
    private func copyRepo(from source: URL, to destination: URL) async throws {
        // Use ditto for efficient copy with resource forks preserved
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw WorkspaceError.copyFailed
        }
    }
}
```

### 2.2 Sidebar with Add Actions

```swift
// Views/MainWindow/SidebarView.swift
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var repos: [Repo]
    @Binding var selectedRepo: Repo?
    @Binding var selectedWorkspace: Workspace?
    
    @State private var isAddingRepo = false
    @State private var newWorkspaceName = ""
    @State private var repoForNewWorkspace: Repo?
    
    var body: some View {
        List(selection: $selectedWorkspace) {
            Section("Repositories") {
                ForEach(repos) { repo in
                    RepoRow(repo: repo)
                        .contextMenu {
                            Button("New Workspace...") {
                                repoForNewWorkspace = repo
                            }
                            Divider()
                            Button("Remove", role: .destructive) {
                                // Remove from list (not delete files)
                            }
                        }
                }
            }
            
            Section("Workspaces") {
                ForEach(repos.flatMap(\.workspaces)) { workspace in
                    WorkspaceRow(workspace: workspace)
                        .tag(workspace)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                isAddingRepo = true
            } label: {
                Label("Add Repository", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding()
        }
        .fileImporter(
            isPresented: $isAddingRepo,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                Task { await addRepo(url) }
            }
        }
        .sheet(item: $repoForNewWorkspace) { repo in
            NewWorkspaceSheet(repo: repo)
        }
    }
}
```

### 2.3 Deliverables

- [x] "Add Repository" opens folder picker
- [x] Repos persist across app launches
- [x] Right-click repo → "New Workspace" creates copy
- [x] Workspaces appear in sidebar, clickable
- [x] Selecting workspace updates context panels; main terminal remains host by default

---

## Phase 3: Right Pane — Files & Changes (Week 5-6)

**Goal**: Tabbed right pane showing file tree and git status.

### 3.1 Git Status Service

```swift
// Services/GitService.swift
actor GitService {
    static let shared = GitService()
    
    func getStatus(at path: URL) async throws -> [FileChange] {
        let output = try await runGit(["status", "--porcelain=v1"], at: path)
        
        return output.split(separator: "\n").compactMap { line in
            let line = String(line)
            guard line.count > 3 else { return nil }
            
            let statusCode = String(line.prefix(2))
            let filePath = String(line.dropFirst(3))
            
            let status: GitStatus = switch statusCode.trimmingCharacters(in: .whitespaces) {
                case "M", "MM": .modified
                case "A": .added
                case "D": .deleted
                case "??": .untracked
                case "R": .renamed
                default: .modified
            }
            
            return FileChange(path: filePath, status: status)
        }
    }
    
    func getFileTree(at path: URL, maxDepth: Int = 3) async throws -> FileNode {
        // Build tree from filesystem, respecting .gitignore
        try await buildTree(at: path, depth: 0, maxDepth: maxDepth)
    }
    
    private func runGit(_ args: [String], at path: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = path
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), 
                     encoding: .utf8) ?? ""
    }
}
```

### 3.2 Right Pane View

```swift
// Views/MainWindow/RightPaneView.swift
struct RightPaneView: View {
    let workspace: Workspace
    @State private var selectedTab: RightPaneTab = .files
    @State private var fileTree: FileNode?
    @State private var changedFiles: [FileChange] = []
    @State private var isLoading = false
    
    enum RightPaneTab: String, CaseIterable {
        case files = "Files"
        case changes = "Changes"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(RightPaneTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
            
            Divider()
            
            // Tab content
            switch selectedTab {
            case .files:
                FileTreeView(root: fileTree)
            case .changes:
                ChangedFilesView(changes: changedFiles)
            }
        }
        .task(id: workspace.id) {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
    }
    
    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        
        async let tree = GitService.shared.getFileTree(at: workspace.path)
        async let status = GitService.shared.getStatus(at: workspace.path)
        
        do {
            fileTree = try await tree
            changedFiles = try await status
        } catch {
            print("Refresh error: \(error)")
        }
    }
}

struct ChangedFilesView: View {
    let changes: [FileChange]
    
    var body: some View {
        List(changes) { change in
            HStack {
                Image(systemName: change.status.icon)
                    .foregroundStyle(change.status.color)
                    .frame(width: 20)
                
                Text(change.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .listStyle(.plain)
        .overlay {
            if changes.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text("Working directory is clean")
                )
            }
        }
    }
}
```

### 3.3 File Watching (Optional Enhancement)

```swift
// Services/FileWatcher.swift
import Combine

class FileWatcher: ObservableObject {
    @Published var lastChange: Date = Date()
    
    private var source: DispatchSourceFileSystemObject?
    
    func watch(directory: URL) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        
        source?.setEventHandler { [weak self] in
            self?.lastChange = Date()
        }
        
        source?.setCancelHandler {
            close(fd)
        }
        
        source?.resume()
    }
    
    func stop() {
        source?.cancel()
        source = nil
    }
}
```

### 3.4 Deliverables

- [x] Right pane has "Files" and "Changes" tabs
- [x] Files tab shows directory tree (collapsible)
- [x] Changes tab shows git status with status icons
- [x] Refresh button / pull-to-refresh updates both
- [ ] File watching triggers auto-refresh (stretch)

---

## Phase 4: Polish & Distribution (Week 7-8)

**Goal**: Window management, keyboard shortcuts, notarization, DMG.

### 4.1 Window & Session Management

```swift
// Multiple windows for multiple workspaces
// App/WindowManager.swift
@MainActor
class WindowManager: ObservableObject {
    static let shared = WindowManager()
    
    func openWorkspace(_ workspace: Workspace) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "\(workspace.name) — \(workspace.sourceRepo.name)"
        window.contentView = NSHostingView(
            rootView: WorkspaceWindowView(workspace: workspace)
        )
        window.makeKeyAndOrderFront(nil)
        window.center()
    }
}
```

### 4.2 Keyboard Shortcuts

```swift
// Common IDE shortcuts
extension ContentView {
    var body: some View {
        mainContent
            .keyboardShortcut("t", modifiers: [.command, .shift]) // New workspace
            .keyboardShortcut("1", modifiers: .command) // Focus sidebar
            .keyboardShortcut("0", modifiers: .command) // Toggle right pane
            .onKeyPress(.return, modifiers: .command) { // Focus terminal
                focusTerminal()
                return .handled
            }
    }
}
```

### 4.3 Notarization Script

```bash
#!/bin/bash
# scripts/notarize.sh

APP_PATH="build/WorkspaceManager.app"
DMG_PATH="build/WorkspaceManager.dmg"
BUNDLE_ID="com.yourcompany.workspacemanager"
TEAM_ID="YOUR_TEAM_ID"
APPLE_ID="your@email.com"
APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # App-specific password

# 1. Archive
xcodebuild archive \
    -scheme WorkspaceManager \
    -archivePath build/WorkspaceManager.xcarchive

# 2. Export
xcodebuild -exportArchive \
    -archivePath build/WorkspaceManager.xcarchive \
    -exportPath build/ \
    -exportOptionsPlist ExportOptions.plist

# 3. Create DMG
hdiutil create -volname "Workspace Manager" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO "$DMG_PATH"

# 4. Notarize
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

# 5. Staple
xcrun stapler staple "$DMG_PATH"

echo "✅ Done: $DMG_PATH"
```

### 4.4 Deliverables

- [ ] Double-click workspace opens new window
- [x] Cmd+Shift+T creates new workspace
- [ ] Cmd+0 toggles right pane
- [ ] App is signed and notarized
- [ ] DMG for distribution
- [x] Basic README with install instructions

---

## Future Enhancements (Post-MVP)

| Feature | Effort | Impact |
|---------|--------|--------|
| **Session history** — persist terminal scrollback | Medium | High |
| **Claude Code integration** — auto-launch `claude` on workspace open | Low | High |
| **Diff viewer** — click changed file to see diff | Medium | Medium |
| **Git operations** — commit, push, pull from UI | Medium | Medium |
| **Workspace templates** — pre-configured setups | Low | Medium |
| **Multi-terminal** — split terminal panes | High | Medium |
| **Search in files** — ripgrep integration | Medium | High |
| **Quick switcher** — Cmd+P to jump workspaces | Low | High |

---

## Dependencies Summary

This section was updated after the terminal migration from SwiftTerm to GhosttyKit.

**Current package/runtime dependencies**:
```swift
// Package.swift
dependencies: []
binaryTarget(
    name: "GhosttyKit",
    path: "Frameworks/GhosttyKit.xcframework"
)
```

**Entitlements** (non-sandboxed):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
```

**Minimum Requirements**:
- macOS 14.0+
- Xcode 15.0+
- Apple Developer account (for notarization)

---

## Quick Reference: Current Project Layout

```text
workspaces/
├── Package.swift
├── Sources/
│   ├── WorkspaceManager/
│   │   ├── App/WorkspaceManagerApp.swift
│   │   ├── Views/MainWindow/ContentView.swift
│   │   ├── Views/Components/TerminalView.swift
│   │   ├── Terminal/GhosttySurfaceView.swift
│   │   └── Resources/
│   └── WorkspaceManagerCore/
│       ├── Models/Models.swift
│       └── Services/
├── Tests/WorkspaceManagerTests/
└── scripts/
    ├── build-ghosttykit.sh
    ├── build-release.sh
    └── notarize.sh
```

> Historical note: earlier roadmap drafts referenced SwiftTerm and an Xcode project layout.
> The current source of truth is GhosttyKit + Swift Package Manager as shown above.

---

## Learnings

### 2026-01-30 — Documentation audit

**Context**: Reviewed project state to plan next work.

**Discovery**: The project is much further along than TASKS.md indicated. Tasks 1-9.5 were all implemented but documentation hadn't been updated:
- Three-column layout, SwiftData persistence, repo/workspace flows all working
- Right pane with file tree and git status complete
- Settings with configurable workspace location done
- 41 unit tests pass (GitService, WorkspaceService, Models)

**What worked**: Code review revealed actual state vs documented state.

**Remaining MVP work**:
- Task 11: Build & Distribution (requires Apple Developer account)
- Stretch items: file watching auto-refresh and multi-window workspace sessions

### 2026-02-08 — Build health validation (post-monorepo extraction)

**Context**: Validated standalone repo after extracting from services monorepo.

**Results**: Clean bill of health — debug build, release build, 52 tests, lint all pass. No monorepo remnants.

**Fixes applied**:
- Updated stale test counts (36 → 52) and task statuses (async migration, error handling already done)
- Fixed ARCHITECTURE.md doc path references
- Removed unused `NSColor(hex:)` extension
- Added release build to CI, `mask run` command
- Removed TASKS.md (GitHub issues is source of truth) and progress.md (stale, replaced by roadmap learnings)

**What worked**: Parallel exploration agents for fast codebase audit. The extraction was clean — zero issues blocking development.
