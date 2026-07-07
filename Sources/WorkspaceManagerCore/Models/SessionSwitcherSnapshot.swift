//
//  SessionSwitcherSnapshot.swift
//  WorkspaceManagerCore
//
//  Read model for the ⌘P session switcher (and, going forward, the shared source of
//  attention-ordered session cards — #680). Builds rows from already-loaded workspace,
//  terminal, web, and agent-status state — no filesystem or git work — and ranks them
//  attention-first (by `SessionActivity.severity`), then query-match tier, then recency.
//  Pure/UI-free; the SwiftUI `SessionSwitcherView` renders these rows.
//

import Foundation
public enum SessionSwitcherCommand: String, Equatable, Sendable {
    case changeTerminalTheme
}

public enum SessionSwitcherTarget: Equatable, Sendable {
    case hostSession(UUID)
    case workspace(UUID)
    case repo(UUID)
    case webSource(UUID)
    case command(SessionSwitcherCommand)
}

public struct SessionSwitcherChip: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(_ title: String, systemImage: String) {
        self.id = "\(systemImage)-\(title)"
        self.title = title
        self.systemImage = systemImage
    }
}

public struct SessionSwitcherRow: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case workspace = "Workspace"
        case repo = "Repo"
        case terminal = "Terminal"
        case web = "Web"
        case command = "Command"
    }

    public let id: String
    public let target: SessionSwitcherTarget
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let preview: String
    public let chips: [SessionSwitcherChip]
    public let activity: SessionActivity
    public let sortDate: Date
    public let isActive: Bool
    private let searchText: String

    public init(
        id: String,
        target: SessionSwitcherTarget,
        kind: Kind,
        title: String,
        subtitle: String,
        preview: String,
        chips: [SessionSwitcherChip],
        activity: SessionActivity,
        sortDate: Date,
        isActive: Bool,
        searchText: String? = nil
    ) {
        self.id = id
        self.target = target
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
        self.chips = chips
        self.activity = activity
        self.sortDate = sortDate
        self.isActive = isActive
        self.searchText =
            searchText
            ?? ([title, subtitle, preview] + chips.map(\.title)).joined(separator: " ")
    }

    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return searchText.localizedStandardContains(query)
    }

    public func matchTier(for query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let normalizedTitle = title.lowercased()
        let normalizedQuery = query.lowercased()
        if normalizedTitle.hasPrefix(normalizedQuery) {
            return 0
        }
        if title.localizedStandardContains(query) {
            return 1
        }
        return 2
    }
}

public struct SessionSwitcherSnapshot: Sendable {
    public static let defaultResultLimit = 50

    public let rows: [SessionSwitcherRow]

    public static func make(
        repos: [Repo],
        webSources: [WebSource],
        sessions: [HostTerminalSession],
        activeSessionID: UUID?,
        agentStatuses: [UUID: AgentSessionStatus],
        paneCountBySessionKey: [HostTerminalSessionKey: Int],
        workspaceSessionKeys: [UUID: HostTerminalSessionKey],
        workspaceActivities: [UUID: SessionActivity],
        repoActivities: [UUID: SessionActivity],
        commands: [SessionSwitcherCommand] = [.changeTerminalTheme],
        now: Date = Date()
    ) -> SessionSwitcherSnapshot {
        let workspaces = repos.flatMap(\.workspaces)
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let reposByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        let paneCountByNormalizedSessionKey = paneCountBySessionKey.reduce(
            into: [HostTerminalSessionKey: Int]()
        ) { result, element in
            result[element.key.normalized()] = element.value
        }
        let workspaceIDBySessionKey = workspaceSessionKeys.reduce(
            into: [HostTerminalSessionKey: UUID]()
        ) { result, element in
            result[element.value.normalized()] = element.key
        }
        let repoIDBySessionKey = repos.reduce(into: [HostTerminalSessionKey: UUID]()) { result, repo in
            result[HostTerminalSessionKey.repoPath(normalizePath(repo.localPath))] = repo.id
        }

        var representedWorkspaceIDs = Set<UUID>()
        var representedRepoIDs = Set<UUID>()
        var rows: [SessionSwitcherRow] = []
        rows.reserveCapacity(sessions.count + workspaces.count + repos.count + webSources.count + commands.count)

        for session in sessions {
            let key = session.key.normalized()
            let status = agentStatuses[session.id]
            let paneCount = paneCountByNormalizedSessionKey[key] ?? 1
            if let workspaceID = workspaceIDBySessionKey[key],
                let workspace = workspacesByID[workspaceID]
            {
                representedWorkspaceIDs.insert(workspaceID)
                rows.append(
                    liveWorkspaceRow(
                        workspace,
                        session: session,
                        status: status,
                        paneCount: paneCount,
                        activity: workspaceActivities[workspaceID] ?? SessionActivity.from(status),
                        isActive: session.id == activeSessionID,
                        now: now
                    )
                )
            } else if let repoID = repoIDBySessionKey[key],
                let repo = reposByID[repoID]
            {
                representedRepoIDs.insert(repoID)
                rows.append(
                    liveRepoRow(
                        repo,
                        session: session,
                        status: status,
                        paneCount: paneCount,
                        activity: repoActivities[repoID] ?? SessionActivity.from(status),
                        isActive: session.id == activeSessionID,
                        now: now
                    )
                )
            } else {
                rows.append(
                    liveTerminalRow(
                        session,
                        status: status,
                        paneCount: paneCount,
                        isActive: session.id == activeSessionID,
                        now: now
                    )
                )
            }
        }

        for workspace in workspaces where !representedWorkspaceIDs.contains(workspace.id) {
            rows.append(dormantWorkspaceRow(workspace))
        }

        for repo in repos where !representedRepoIDs.contains(repo.id) {
            rows.append(dormantRepoRow(repo))
        }

        rows.append(contentsOf: webSources.map(webSourceRow))
        rows.append(contentsOf: commands.map(commandRow))

        return SessionSwitcherSnapshot(rows: rank(rows, query: "", limit: nil))
    }

    public static func rank(
        _ rows: [SessionSwitcherRow],
        query: String,
        limit: Int? = defaultResultLimit
    ) -> [SessionSwitcherRow] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = rows.filter { $0.matches(normalizedQuery) }
        let ranked = filtered.sorted { lhs, rhs in
            // Attention-first: the single severity ladder lives on `SessionActivity`
            // (errored > awaitingInput > running/thinking > active > live > inactive).
            let lhsSeverity = lhs.activity.severity
            let rhsSeverity = rhs.activity.severity
            if lhsSeverity != rhsSeverity { return lhsSeverity > rhsSeverity }

            let lhsTier = lhs.matchTier(for: normalizedQuery)
            let rhsTier = rhs.matchTier(for: normalizedQuery)
            if lhsTier != rhsTier { return lhsTier < rhsTier }

            if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        guard let limit else { return ranked }
        return Array(ranked.prefix(limit))
    }

    private static func liveWorkspaceRow(
        _ workspace: Workspace,
        session: HostTerminalSession,
        status: AgentSessionStatus?,
        paneCount: Int,
        activity: SessionActivity,
        isActive: Bool,
        now: Date
    ) -> SessionSwitcherRow {
        SessionSwitcherRow(
            id: "session-\(session.id.uuidString)",
            target: .hostSession(session.id),
            kind: .workspace,
            title: workspace.name,
            subtitle: subtitle(parts: [workspace.sourceRepo?.name, session.directoryPath]),
            preview: preview(for: status, fallback: "Live terminal session"),
            chips: chips(
                status: status,
                branch: workspace.gitBranch,
                paneCount: paneCount,
                sessionID: session.id,
                now: now
            ),
            activity: activityForRow(activity: activity, isActive: isActive),
            sortDate: status?.lastEventAt ?? workspace.lastAccessedAt,
            isActive: isActive
        )
    }

    private static func liveRepoRow(
        _ repo: Repo,
        session: HostTerminalSession,
        status: AgentSessionStatus?,
        paneCount: Int,
        activity: SessionActivity,
        isActive: Bool,
        now: Date
    ) -> SessionSwitcherRow {
        SessionSwitcherRow(
            id: "session-\(session.id.uuidString)",
            target: .hostSession(session.id),
            kind: .repo,
            title: repo.name,
            subtitle: session.directoryPath,
            preview: preview(for: status, fallback: "Live repo terminal"),
            chips: chips(status: status, branch: nil, paneCount: paneCount, sessionID: session.id, now: now),
            activity: activityForRow(activity: activity, isActive: isActive),
            sortDate: status?.lastEventAt ?? repo.lastAccessedAt,
            isActive: isActive
        )
    }

    private static func liveTerminalRow(
        _ session: HostTerminalSession,
        status: AgentSessionStatus?,
        paneCount: Int,
        isActive: Bool,
        now: Date
    ) -> SessionSwitcherRow {
        SessionSwitcherRow(
            id: "session-\(session.id.uuidString)",
            target: .hostSession(session.id),
            kind: .terminal,
            title: URL(fileURLWithPath: session.directoryPath).lastPathComponent,
            subtitle: session.key.debugDescription,
            preview: preview(for: status, fallback: session.customCommand ?? "Live terminal session"),
            chips: chips(status: status, branch: nil, paneCount: paneCount, sessionID: session.id, now: now),
            activity: activityForRow(activity: SessionActivity.from(status), isActive: isActive),
            sortDate: status?.lastEventAt ?? .distantPast,
            isActive: isActive
        )
    }

    private static func dormantWorkspaceRow(_ workspace: Workspace) -> SessionSwitcherRow {
        var chips: [SessionSwitcherChip] = []
        if let branch = workspace.gitBranch, !branch.isEmpty {
            chips.append(SessionSwitcherChip(branch, systemImage: "arrow.triangle.branch"))
        }
        chips.append(SessionSwitcherChip(workspace.status.rawValue, systemImage: "circle"))
        return SessionSwitcherRow(
            id: "workspace-\(workspace.id.uuidString)",
            target: .workspace(workspace.id),
            kind: .workspace,
            title: workspace.name,
            subtitle: subtitle(parts: [workspace.sourceRepo?.name, workspace.path]),
            preview: "No live terminal session",
            chips: chips,
            activity: .inactive,
            sortDate: workspace.lastAccessedAt,
            isActive: false
        )
    }

    private static func dormantRepoRow(_ repo: Repo) -> SessionSwitcherRow {
        SessionSwitcherRow(
            id: "repo-\(repo.id.uuidString)",
            target: .repo(repo.id),
            kind: .repo,
            title: repo.name,
            subtitle: repo.localPath,
            preview: repo.workspaces.isEmpty ? "No workspaces yet" : "\(repo.workspaces.count) workspaces",
            chips: [SessionSwitcherChip("repo", systemImage: "folder")],
            activity: .inactive,
            sortDate: repo.lastAccessedAt,
            isActive: false
        )
    }

    private static func webSourceRow(_ source: WebSource) -> SessionSwitcherRow {
        var chips = [SessionSwitcherChip("web", systemImage: "globe")]
        if let host = source.baseURL?.host, !host.isEmpty {
            chips.append(SessionSwitcherChip(host, systemImage: "network"))
        }
        if let repoName = source.ownerRepo?.name, !repoName.isEmpty {
            chips.append(SessionSwitcherChip(repoName, systemImage: "folder"))
        }
        return SessionSwitcherRow(
            id: "web-\(source.id.uuidString)",
            target: .webSource(source.id),
            kind: .web,
            title: source.name,
            subtitle: webSubtitle(for: source),
            preview: source.baseURLString,
            chips: chips,
            activity: .inactive,
            sortDate: source.lastAccessedAt,
            isActive: false,
            searchText: subtitle(
                parts: [
                    source.name,
                    source.baseURLString,
                    source.baseURL?.host,
                    source.ownerRepo?.name,
                ]
            )
        )
    }

    private static func commandRow(_ command: SessionSwitcherCommand) -> SessionSwitcherRow {
        switch command {
        case .changeTerminalTheme:
            return SessionSwitcherRow(
                id: "command-change-terminal-theme",
                target: .command(command),
                kind: .command,
                title: "Change Terminal Theme...",
                subtitle: "Command - Shift-Command-P",
                preview: "Open terminal theme picker",
                chips: [SessionSwitcherChip("command", systemImage: "command")],
                activity: .inactive,
                sortDate: .distantFuture,
                isActive: false
            )
        }
    }

    private static func chips(
        status: AgentSessionStatus?,
        branch: String?,
        paneCount: Int,
        sessionID: UUID,
        now: Date
    ) -> [SessionSwitcherChip] {
        var chips: [SessionSwitcherChip] = []
        if let branch, !branch.isEmpty {
            chips.append(SessionSwitcherChip(branch, systemImage: "arrow.triangle.branch"))
        }
        if paneCount > 1 {
            chips.append(SessionSwitcherChip("\(paneCount) panes", systemImage: "rectangle.split.2x1"))
        }
        if let kind = status?.kind, kind != .unknown {
            chips.append(SessionSwitcherChip(kind.displayName, systemImage: "sparkles"))
        }
        if let model = status?.modelDisplayName, !model.isEmpty {
            chips.append(SessionSwitcherChip(model, systemImage: "cpu"))
        }
        if let context = status?.contextUsedPercent {
            chips.append(SessionSwitcherChip("\(Int(context.rounded()))% ctx", systemImage: "gauge.medium"))
        }
        if let cost = status?.costUSD {
            chips.append(SessionSwitcherChip(String(format: "$%.2f", cost), systemImage: "dollarsign.circle"))
        }
        if let lastEventAt = status?.lastEventAt {
            chips.append(SessionSwitcherChip(relativeTime(from: lastEventAt, to: now), systemImage: "clock"))
        }
        chips.append(SessionSwitcherChip(shortID(sessionID), systemImage: "number"))
        return chips
    }

    private static func preview(for status: AgentSessionStatus?, fallback: String) -> String {
        guard let status else { return fallback }
        switch status.run {
        case .idle:
            return "Idle"
        case .thinking:
            return "Thinking"
        case .runningTool(let name, let detail):
            return subtitle(parts: ["Running \(name)", detail])
        case .awaitingInput(let reason):
            return "Awaiting input: \(reason.displayName)"
        case .complete:
            return "Complete"
        case .errored(_, let message):
            return message ?? "Errored"
        }
    }

    private static func activityForRow(activity: SessionActivity, isActive: Bool) -> SessionActivity {
        if isActive, activity == .inactive || activity == .live {
            return .active
        }
        return activity
    }

    private static func webSubtitle(for source: WebSource) -> String {
        var parts: [String] = ["Web"]
        if let host = source.baseURL?.host, !host.isEmpty { parts.append(host) }
        if let repoName = source.ownerRepo?.name { parts.append(repoName) }
        return parts.joined(separator: " - ")
    }

    private static func subtitle(parts: [String?]) -> String {
        let values = parts.compactMap { value -> String? in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                !trimmed.isEmpty
            else {
                return nil
            }
            return trimmed
        }
        return values.joined(separator: " - ")
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private static func relativeTime(from date: Date, to now: Date) -> String {
        let interval = max(0, Int(now.timeIntervalSince(date)))
        if interval < 60 { return "\(interval)s ago" }
        if interval < 3600 { return "\(interval / 60)m ago" }
        if interval < 86_400 { return "\(interval / 3600)h ago" }
        return "\(interval / 86_400)d ago"
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
