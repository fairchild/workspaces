//
//  SwitchableItem.swift
//  WorkspaceManager
//
//  Lightweight abstraction over things the ⌘P command palette can switch to.
//  Phase 2/3 features (Timeline events, archived workspaces, recent agents)
//  add their own adapters without touching the view.
//

import Foundation
import WorkspaceManagerCore

/// Selection callbacks the palette can invoke when an item is activated.
/// Each adapter knows which one to call.
struct SwitchableContext {
    let selectWorkspace: (Workspace) -> Void
    let selectRepo: (Repo) -> Void
    let selectWebSource: (WebSource) -> Void
}

/// A single row in the command palette.
protocol SwitchableItem: Identifiable {
    var title: String { get }
    var subtitle: String { get }
    /// Used to rank tied query matches — typically a `lastAccessedAt` date.
    var sortKey: Date { get }
    /// Status dot the row should render. `.inactive` produces no dot.
    var indicator: SidebarSessionActivity { get }
    func matches(_ query: String) -> Bool
    func activate(_ context: SwitchableContext)
}

struct WorkspaceSwitchableItem: SwitchableItem {
    let workspace: Workspace
    let indicator: SidebarSessionActivity
    let waitingDescriptor: String?

    var id: UUID { workspace.id }
    var title: String { workspace.name }
    var subtitle: String {
        var parts: [String] = []
        if let repoName = workspace.sourceRepo?.name { parts.append(repoName) }
        if let waitingDescriptor { parts.append(waitingDescriptor) }
        if let branch = workspace.gitBranch, !branch.isEmpty { parts.append(branch) }
        return parts.isEmpty ? "Workspace" : parts.joined(separator: " · ")
    }
    var sortKey: Date { workspace.lastAccessedAt }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return workspace.name.localizedCaseInsensitiveContains(query)
            || (workspace.sourceRepo?.name.localizedCaseInsensitiveContains(query) ?? false)
            || (workspace.gitBranch?.localizedCaseInsensitiveContains(query) ?? false)
    }

    func activate(_ context: SwitchableContext) {
        context.selectWorkspace(workspace)
    }
}

struct RepoSwitchableItem: SwitchableItem {
    let repo: Repo
    let indicator: SidebarSessionActivity

    var id: UUID { repo.id }
    var title: String { repo.name }
    var subtitle: String {
        let count = repo.workspaces.count
        return count == 0
            ? "Repository"
            : "Repository · \(count) workspace\(count == 1 ? "" : "s")"
    }
    var sortKey: Date { repo.lastAccessedAt }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return repo.name.localizedCaseInsensitiveContains(query)
    }

    func activate(_ context: SwitchableContext) {
        context.selectRepo(repo)
    }
}

struct WebSourceSwitchableItem: SwitchableItem {
    let source: WebSource

    var id: UUID { source.id }
    var indicator: SidebarSessionActivity { .inactive }
    var title: String { source.name }
    var subtitle: String {
        var parts: [String] = ["Web"]
        if let host = source.baseURL?.host, !host.isEmpty { parts.append(host) }
        if let repoName = source.ownerRepo?.name { parts.append(repoName) }
        return parts.joined(separator: " · ")
    }
    var sortKey: Date { source.lastAccessedAt }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return source.name.localizedCaseInsensitiveContains(query)
            || source.baseURLString.localizedCaseInsensitiveContains(query)
            || (source.baseURL?.host?.localizedCaseInsensitiveContains(query) ?? false)
    }

    func activate(_ context: SwitchableContext) {
        context.selectWebSource(source)
    }
}
