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
    let onWebSourceSelected: (WebSource) -> Void
    let onOpenTerminal: (Repo) -> Void
    let onNewWorkspace: (Repo) -> Void
    let onNewWebSource: (Repo) -> Void
    let onArchiveWorkspace: (Workspace) -> Void
    let onOpenWorkspaceInEditor: (Workspace) -> Void

    @State private var agentStatuses: [UUID: WorkspaceProcessMonitor.AgentStatus] = [:]
    @State private var bridge = RepoLandingBridge()

    private var sortedWorkspaces: [Workspace] {
        repo.workspaces.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private var sortedRepoWebSources: [WebSource] {
        repo.webSources.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            repoHeader
            Divider()
            if let webIndexURL = resolvedWebIndex {
                RepoLandingWebView(indexURL: webIndexURL, bridge: bridge)
                    .id(repo.id)
            } else {
                overviewContent
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
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayPath(repo.localPath))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(sortedWorkspaces.count) workspace\(sortedWorkspaces.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    onOpenTerminal(repo)
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .buttonStyle(.bordered)

                Button {
                    onNewWorkspace(repo)
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Overview

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                workspacesSection
                webViewsSection
            }
            .padding(20)
        }
    }

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Workspaces")

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
        }
    }

    private var webViewsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Web Views")
                    .font(.headline)

                Spacer()

                Button {
                    onNewWebSource(repo)
                } label: {
                    Label("Add Web View", systemImage: "plus")
                }
            }

            if sortedRepoWebSources.isEmpty {
                ContentUnavailableView(
                    "No Repo Web Views",
                    systemImage: "globe",
                    description: Text("Add repo-specific docs, dashboards, or tools here.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(sortedRepoWebSources) { source in
                        Button {
                            onWebSourceSelected(source)
                        } label: {
                            RepoOverviewWebSourceRow(source: source)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    private func displayPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
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
            VStack(alignment: .leading, spacing: 10) {
                // Branch + status
                HStack {
                    Text(workspace.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    statusBadge
                }

                ForEach(agentStatus.processes, id: \.displayName) { proc in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(proc.isKnownAgent ? Color.accentColor : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(proc.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                HStack {
                    if let branch = workspace.gitBranch, branch.isEmpty == false {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(workspace.lastAccessedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
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
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
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

private struct RepoOverviewWebSourceRow: View {
    let source: WebSource

    var body: some View {
        HStack(spacing: 12) {
            WebSourceFaviconView(source: source)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(source.allowedHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
    }
}
