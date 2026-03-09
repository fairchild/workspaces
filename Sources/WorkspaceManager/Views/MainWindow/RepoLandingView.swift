//
//  RepoLandingView.swift
//  WorkspaceManager
//
//  Landing page shown when clicking a repo — overview of all workspaces.
//

import AppKit
import SwiftUI
import WebKit
import WorkspaceManagerCore

struct RepoLandingView: View {
    @Environment(\.workspaceProcessMonitor) private var processMonitor

    let repo: Repo
    let onWorkspaceSelected: (Workspace) -> Void
    let onOpenTerminal: (Repo) -> Void
    let onNewWorkspace: (Repo) -> Void
    let onArchiveWorkspace: (Workspace) -> Void
    let onOpenWorkspaceInEditor: (Workspace) -> Void

    @State private var agentStatuses: [UUID: WorkspaceProcessMonitor.AgentStatus] = [:]
    @State private var bridge = RepoLandingBridge()

    private var sortedWorkspaces: [Workspace] {
        repo.workspaces.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            repoHeader
            Divider()
            if let webIndexURL = resolvedWebIndex {
                RepoLandingWebView(indexURL: webIndexURL, bridge: bridge)
                    .id(repo.id)
            } else {
                workspaceGrid
            }
        }
        .navigationTitle(repo.name)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: repo.id) {
            await MainActor.run {
                configureBridge()
            }
            await pollAgentStatuses()
        }
    }

    // MARK: - Web Index Resolution

    private var resolvedWebIndex: URL? {
        // 1. Repo-local override
        let repoWeb = repo.localURL.appendingPathComponent(".agents/workspaces/index.html")
        if FileManager.default.fileExists(atPath: repoWeb.path) { return repoWeb }
        // 2. User-global override
        let globalWeb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/workspaces/index.html")
        if FileManager.default.fileExists(atPath: globalWeb.path) { return globalWeb }
        // No bundled default — native SwiftUI grid is the default
        return nil
    }

    // MARK: - Bridge Wiring

    @MainActor
    private func configureBridge() {
        bridge.onReady = { pushDataToWeb() }
        bridge.onSelectWorkspace = { idString in
            if let workspace = repo.workspaces.first(where: { $0.id.uuidString == idString }) {
                onWorkspaceSelected(workspace)
            }
        }
        bridge.onCreateWorkspace = { onNewWorkspace(repo) }
        bridge.onOpenTerminal = { onOpenTerminal(repo) }
        bridge.onArchiveWorkspace = { idString in
            if let workspace = repo.workspaces.first(where: { $0.id.uuidString == idString }) {
                onArchiveWorkspace(workspace)
            }
        }
        bridge.onOpenInEditor = { idString in
            if let workspace = repo.workspaces.first(where: { $0.id.uuidString == idString }) {
                onOpenWorkspaceInEditor(workspace)
            }
        }
        bridge.onRevealInFinder = { idString in
            if let workspace = repo.workspaces.first(where: { $0.id.uuidString == idString }) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
            }
        }
        // Push data immediately — if the web view is already ready, it renders now.
        // If not yet ready, the bridge queues it and delivers on "ready".
        pushDataToWeb()
    }

    // MARK: - Header

    private var repoHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(repo.localPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                onOpenTerminal(repo)
            } label: {
                Label("Terminal", systemImage: "terminal")
            }

            Button {
                onNewWorkspace(repo)
            } label: {
                Label("New Workspace", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Grid

    private var workspaceGrid: some View {
        ScrollView {
            let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(sortedWorkspaces) { workspace in
                    WorkspaceCardView(
                        workspace: workspace,
                        agentStatus: agentStatuses[workspace.id] ?? .inactive,
                        onSelect: { onWorkspaceSelected(workspace) }
                    )
                }

                NewWorkspaceCardView {
                    onNewWorkspace(repo)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Agent Polling

    private func pollAgentStatuses() async {
        while !Task.isCancelled {
            let directories = Dictionary(
                uniqueKeysWithValues: sortedWorkspaces.map { ($0.id, $0.workspaceURL) }
            )
            let statuses = await processMonitor.detectAgents(in: directories)
            await MainActor.run {
                agentStatuses = statuses
                pushDataToWeb()
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    // MARK: - Web Data Push

    @MainActor
    private func pushDataToWeb() {
        guard resolvedWebIndex != nil else { return }
        let data = RepoLandingData(
            repo: .init(
                name: repo.name,
                localPath: repo.localPath,
                remoteURL: repo.remoteURL
            ),
            workspaces: sortedWorkspaces.map { ws in
                let status = agentStatuses[ws.id] ?? .inactive
                return .init(
                    id: ws.id.uuidString,
                    name: ws.name,
                    branch: ws.gitBranch,
                    path: ws.path,
                    status: ws.status.rawValue,
                    lastAccessedAt: ws.lastAccessedAt.timeIntervalSince1970,
                    isAgentRunning: status.isAgentRunning,
                    agentName: status.agentName,
                    processes: status.processes.map {
                        .init(displayName: $0.displayName, isKnownAgent: $0.isKnownAgent)
                    }
                )
            }
        )
        bridge.pushData(data)
    }
}

// MARK: - Workspace Card

struct WorkspaceCardView: View {
    let workspace: Workspace
    let agentStatus: WorkspaceProcessMonitor.AgentStatus
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // Branch + status
                HStack {
                    Text(workspace.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    statusBadge
                }

                if let branch = workspace.gitBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ForEach(agentStatus.processes, id: \.displayName) { proc in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(proc.isKnownAgent ? .green : .blue)
                            .frame(width: 6, height: 6)
                        Text(proc.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()

                HStack {
                    Spacer()

                    Text(workspace.lastAccessedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch workspace.status {
        case .active:
            Text("Active")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12), in: Capsule())
        case .stopped:
            Text("Stopped")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.12), in: Capsule())
        case .archived:
            Text("Archived")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.08), in: Capsule())
        }
    }
}

// MARK: - New Workspace Card

struct NewWorkspaceCardView: View {
    let onCreate: () -> Void

    var body: some View {
        Button(action: onCreate) {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "plus.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("New Workspace")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
            }
        }
        .buttonStyle(.plain)
    }
}
