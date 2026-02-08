//
//  RightPaneView.swift
//  WorkspaceManager
//
//  Collapsible right pane with Files and Changes tabs
//

import SwiftUI
import WorkspaceManagerCore

struct RightPaneView: View {
    let workspace: Workspace

    @Environment(\.gitService) private var gitService
    @State private var selectedTab: Tab = .files
    @State private var fileTree: FileNode?
    @State private var changedFiles: [FileChange] = []
    @State private var isLoading = false
    @State private var lastRefresh = Date()

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

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    TabButton(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isSelected: selectedTab == tab,
                        badge: tab == .changes ? changedFiles.count : nil
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Tab content
            ZStack {
                switch selectedTab {
                case .files:
                    FileTreeTabView(root: fileTree, isLoading: isLoading)
                case .changes:
                    ChangedFilesTabView(changes: changedFiles, isLoading: isLoading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer with refresh
            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Updated \(lastRefresh.formatted(.relative(presentation: .named)))")
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
                .disabled(isLoading)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .task(id: workspace.id) {
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        defer {
            isLoading = false
            lastRefresh = Date()
        }

        async let treeTask = loadFileTree()
        async let statusTask = loadGitStatus()

        (fileTree, changedFiles) = await (treeTask, statusTask)
    }

    private func loadFileTree() async -> FileNode? {
        do {
            return try await gitService.getFileTree(at: workspace.workspaceURL)
        } catch {
            print("Failed to load file tree: \(error)")
            return nil
        }
    }

    private func loadGitStatus() async -> [FileChange] {
        do {
            return try await gitService.getStatus(at: workspace.workspaceURL)
        } catch {
            print("Failed to load git status: \(error)")
            return []
        }
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

    var body: some View {
        if let root {
            List {
                FileNodeView(node: root, level: 0)
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
    let level: Int

    @State private var isExpanded = false

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children ?? []) { child in
                    FileNodeView(node: child, level: level + 1)
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
            }
        } else {
            Label(node.name, systemImage: node.icon)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Changes Tab

struct ChangedFilesTabView: View {
    let changes: [FileChange]
    let isLoading: Bool

    var body: some View {
        if changes.isEmpty && !isLoading {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("Working directory is clean")
            )
        } else {
            List(changes) { change in
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
            .listStyle(.plain)
        }
    }
}

// FileNode is defined in Models/Models.swift
