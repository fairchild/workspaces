//
//  RightPaneView.swift
//  WorkspaceManager
//
//  Collapsible right pane with Files and Changes tabs
//

import SwiftUI
import WorkspaceManagerCore

@MainActor
final class RightPaneSessionState: ObservableObject {
    @Published var selectedTab: RightPaneView.Tab = .files
    @Published var fileTree: FileNode?
    @Published var changedFiles: [FileChange] = []
    @Published var isLoading = false
    @Published var lastRefresh = Date()
    @Published var expandedDirectoryPaths: Set<String> = []
    @Published var hasLoadedOnce = false
}

@MainActor
final class RightPaneStateStore: ObservableObject {
    private var states: [String: RightPaneSessionState] = [:]

    func state(for targetID: String) -> RightPaneSessionState {
        if let existing = states[targetID] {
            return existing
        }
        let created = RightPaneSessionState()
        states[targetID] = created
        return created
    }

    func state(for workspace: Workspace) -> RightPaneSessionState {
        state(for: "workspace-\(workspace.id.uuidString)")
    }

    func state(for repo: Repo) -> RightPaneSessionState {
        state(for: "repo-\(repo.id.uuidString)")
    }

    func prune(keeping validTargetIDs: Set<String>) {
        guard !states.isEmpty else { return }
        states = states.filter { validTargetIDs.contains($0.key) }
    }
}

struct RightPaneView: View {
    let targetID: String
    let directoryURL: URL
    let onFileSelected: (CodePreviewSelection) -> Void

    @Environment(\.gitService) private var gitService
    @ObservedObject private var state: RightPaneSessionState

    enum Tab: String, CaseIterable {
        case files = "Files"
        case changes = "Changes"

        var icon: String {
            switch self {
            case .files: return "folder"
            case .changes: return "arrow.triangle.2.circlepath"
            }
        }
    }

    init(
        workspace: Workspace,
        state: RightPaneSessionState,
        onFileSelected: @escaping (CodePreviewSelection) -> Void = { _ in }
    ) {
        self.targetID = "workspace-\(workspace.id.uuidString)"
        self.directoryURL = workspace.workspaceURL
        self.state = state
        self.onFileSelected = onFileSelected
    }

    init(
        repo: Repo,
        state: RightPaneSessionState,
        onFileSelected: @escaping (CodePreviewSelection) -> Void = { _ in }
    ) {
        self.targetID = "repo-\(repo.id.uuidString)"
        self.directoryURL = repo.localURL
        self.state = state
        self.onFileSelected = onFileSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    TabButton(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isSelected: state.selectedTab == tab,
                        badge: tab == .changes ? state.changedFiles.count : nil
                    ) {
                        state.selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Tab content
            ZStack {
                switch state.selectedTab {
                case .files:
                    FileTreeTabView(
                        root: state.fileTree,
                        isLoading: state.isLoading,
                        expandedDirectoryPaths: $state.expandedDirectoryPaths,
                        onFileSelected: selectFile
                    )
                case .changes:
                    ChangedFilesTabView(
                        changes: state.changedFiles,
                        isLoading: state.isLoading,
                        onFileSelected: selectFile
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer with refresh
            HStack {
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Updated \(state.lastRefresh.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state.isLoading)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .task(id: targetID) {
            if !state.hasLoadedOnce || state.fileTree == nil {
                await refresh()
            }
        }
    }

    @MainActor
    private func refresh() async {
        state.isLoading = true
        defer {
            state.isLoading = false
            state.lastRefresh = Date()
            state.hasLoadedOnce = true
        }

        async let treeTask = loadFileTree()
        async let statusTask = loadGitStatus()

        let (fileTree, changedFiles) = await (treeTask, statusTask)
        state.fileTree = fileTree
        state.changedFiles = changedFiles
    }

    private func loadFileTree() async -> FileNode? {
        do {
            return try await gitService.getFileTree(at: directoryURL)
        } catch {
            print("Failed to load file tree: \(error)")
            return nil
        }
    }

    private func loadGitStatus() async -> [FileChange] {
        do {
            return try await gitService.getStatus(at: directoryURL)
        } catch {
            print("Failed to load git status: \(error)")
            return []
        }
    }

    private func selectFile(relativePath: String) {
        guard !relativePath.isEmpty else { return }
        onFileSelected(
            CodePreviewSelection(
                rootURL: directoryURL,
                relativePath: relativePath
            )
        )
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)

                Text(title)
                    .font(.caption)

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? .white.opacity(0.3) : .secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Files Tab

struct FileTreeTabView: View {
    let root: FileNode?
    let isLoading: Bool
    @Binding var expandedDirectoryPaths: Set<String>
    let onFileSelected: (String) -> Void

    var body: some View {
        if let root {
            List {
                ForEach(root.children ?? [], id: \.path) { child in
                    FileNodeView(
                        node: child,
                        expandedDirectoryPaths: $expandedDirectoryPaths,
                        onFileSelected: onFileSelected
                    )
                }
            }
            .listStyle(.plain)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Files",
                systemImage: "folder",
                description: Text("Could not load file tree")
            )
        }
    }
}

struct FileNodeView: View {
    let node: FileNode
    @Binding var expandedDirectoryPaths: Set<String>
    let onFileSelected: (String) -> Void

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { expandedDirectoryPaths.contains(node.path) },
            set: { shouldExpand in
                if shouldExpand {
                    expandedDirectoryPaths.insert(node.path)
                } else {
                    expandedDirectoryPaths.remove(node.path)
                }
            }
        )
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: isExpandedBinding) {
                ForEach(node.children ?? [], id: \.path) { child in
                    FileNodeView(
                        node: child,
                        expandedDirectoryPaths: $expandedDirectoryPaths,
                        onFileSelected: onFileSelected
                    )
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
            }
        } else {
            Button {
                onFileSelected(node.path)
            } label: {
                Label(node.name, systemImage: node.icon)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Changes Tab

struct ChangedFilesTabView: View {
    let changes: [FileChange]
    let isLoading: Bool
    let onFileSelected: (String) -> Void

    var body: some View {
        if changes.isEmpty && !isLoading {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("Working directory is clean")
            )
        } else {
            List(changes) { change in
                Button {
                    onFileSelected(change.path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: change.status.icon)
                            .foregroundStyle(change.status.color)
                            .frame(width: 16)

                        Text(change.path)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

// FileNode is defined in Models/Models.swift
