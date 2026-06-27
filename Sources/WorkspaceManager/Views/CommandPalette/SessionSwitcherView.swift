//
//  SessionSwitcherView.swift
//  WorkspaceManager
//
//  Searchable session switcher for Cmd-P. It builds rows from already-loaded
//  workspace, terminal, web, and agent status state so opening the switcher
//  does not perform filesystem or git work.
//

import SwiftUI
import WorkspaceManagerCore

enum SessionSwitcherCommand: String, Equatable {
    case changeTerminalTheme
}

enum SessionSwitcherTarget: Equatable {
    case hostSession(UUID)
    case workspace(UUID)
    case repo(UUID)
    case webSource(UUID)
    case command(SessionSwitcherCommand)
}

struct SessionSwitcherChip: Equatable, Identifiable {
    let id: String
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.id = "\(systemImage)-\(title)"
        self.title = title
        self.systemImage = systemImage
    }
}

struct SessionSwitcherRow: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case workspace = "Workspace"
        case repo = "Repo"
        case terminal = "Terminal"
        case web = "Web"
        case command = "Command"
    }

    let id: String
    let target: SessionSwitcherTarget
    let kind: Kind
    let title: String
    let subtitle: String
    let preview: String
    let chips: [SessionSwitcherChip]
    let activity: SidebarSessionActivity
    let sortDate: Date
    let isActive: Bool
    private let searchText: String

    init(
        id: String,
        target: SessionSwitcherTarget,
        kind: Kind,
        title: String,
        subtitle: String,
        preview: String,
        chips: [SessionSwitcherChip],
        activity: SidebarSessionActivity,
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

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return searchText.localizedStandardContains(query)
    }

    func matchTier(for query: String) -> Int {
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

struct SessionSwitcherSnapshot {
    let rows: [SessionSwitcherRow]

    static func make(
        repos: [Repo],
        webSources: [WebSource],
        sessions: [HostTerminalSession],
        activeSessionID: UUID?,
        agentStatuses: [UUID: AgentSessionStatus],
        paneCountBySessionKey: [HostTerminalSessionKey: Int],
        workspaceSessionKeys: [UUID: HostTerminalSessionKey],
        workspaceActivities: [UUID: SidebarSessionActivity],
        repoActivities: [UUID: SidebarSessionActivity],
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
                        activity: workspaceActivities[workspaceID] ?? SidebarSessionActivity.from(status),
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
                        activity: repoActivities[repoID] ?? SidebarSessionActivity.from(status),
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

        return SessionSwitcherSnapshot(rows: rank(rows, query: ""))
    }

    static func rank(_ rows: [SessionSwitcherRow], query: String, limit: Int? = nil) -> [SessionSwitcherRow] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = rows.filter { $0.matches(normalizedQuery) }
        let ranked = filtered.sorted { lhs, rhs in
            let lhsPriority = priority(lhs)
            let rhsPriority = priority(rhs)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

            let lhsTier = lhs.matchTier(for: normalizedQuery)
            let rhsTier = rhs.matchTier(for: normalizedQuery)
            if lhsTier != rhsTier { return lhsTier < rhsTier }

            if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        guard let limit else { return ranked }
        return Array(ranked.prefix(limit))
    }

    private static func priority(_ row: SessionSwitcherRow) -> Int {
        switch row.activity {
        case .errored: return 0
        case .awaitingInput: return 1
        case .runningTool, .thinking: return 2
        case .active: return 3
        case .live: return 4
        case .inactive: return 5
        }
    }

    private static func liveWorkspaceRow(
        _ workspace: Workspace,
        session: HostTerminalSession,
        status: AgentSessionStatus?,
        paneCount: Int,
        activity: SidebarSessionActivity,
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
        activity: SidebarSessionActivity,
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
            activity: activityForRow(activity: SidebarSessionActivity.from(status), isActive: isActive),
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

    private static func activityForRow(activity: SidebarSessionActivity, isActive: Bool) -> SidebarSessionActivity {
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

struct SessionSwitcherView: View {
    let snapshot: SessionSwitcherSnapshot
    let repos: [Repo]
    let webSources: [WebSource]
    let onSelectWorkspace: (Workspace) -> Void
    let onSelectRepo: (Repo) -> Void
    let onSelectWebSource: (WebSource) -> Void
    let onSelectHostSession: (UUID) -> Void
    let onOpenThemeSwitcher: () -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var queryFieldFocused: Bool

    private var rows: [SessionSwitcherRow] {
        SessionSwitcherSnapshot.rank(snapshot.rows, query: query)
    }

    private var reposByID: [UUID: Repo] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
    }

    private var webSourcesByID: [UUID: WebSource] {
        Dictionary(uniqueKeysWithValues: webSources.map { ($0.id, $0) })
    }

    private var workspacesByID: [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: repos.flatMap(\.workspaces).map { ($0.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            queryField
            Divider()
            resultsList
        }
        .frame(width: 720, height: 520)
        .background(.thinMaterial)
        .onAppear {
            queryFieldFocused = true
        }
    }

    private var queryField: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.stack.badge.play")
                .foregroundStyle(.secondary)
            TextField("Search sessions, repos, branches, agents", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($queryFieldFocused)
                .accessibilityIdentifier("session-switcher-search")
                .onSubmit(activateHighlightedRow)
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
        }
    }

    private var resultsList: some View {
        let rows = rows
        return Group {
            if rows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            Button {
                                highlightedIndex = index
                                activate(row)
                            } label: {
                                rowView(row, isHighlighted: index == highlightedIndex)
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                            .listRowSeparator(.hidden)
                            .listRowBackground(rowBackground(isHighlighted: index == highlightedIndex))
                            .accessibilityIdentifier("session-switcher-row-\(row.id)")
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: highlightedIndex) { _, newIndex in
                        guard newIndex >= 0, newIndex < rows.count else { return }
                        proxy.scrollTo(rows[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "No sessions yet." : "No results for \"\(query)\"")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowView(_ row: SessionSwitcherRow, isHighlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: iconName(for: row))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isHighlighted ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                if row.activity.hasLiveSession {
                    Circle()
                        .fill(row.activity.indicatorColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: 1)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.callout.weight(isHighlighted || row.isActive ? .semibold : .regular))
                        .lineLimit(1)
                    Text(row.kind.rawValue)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.08)))
                }
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(row.preview)
                    .font(.caption)
                    .foregroundStyle(row.activity == .awaitingInput ? .primary : .secondary)
                    .lineLimit(1)
                chipRow(row.chips)
            }
            Spacer(minLength: 8)
            if row.isActive {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.kind.rawValue), \(row.preview)")
    }

    private func chipRow(_ chips: [SessionSwitcherChip]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(chips) { chip in
                    Label(chip.title, systemImage: chip.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.07)))
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 20)
    }

    private func rowBackground(isHighlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }

    private func iconName(for row: SessionSwitcherRow) -> String {
        switch row.kind {
        case .workspace: return "terminal"
        case .repo: return "folder"
        case .terminal: return "rectangle.terminal"
        case .web: return "globe"
        case .command: return "command"
        }
    }

    private func moveHighlight(by delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        highlightedIndex = max(0, min(rows.count - 1, highlightedIndex + delta))
    }

    private func activateHighlightedRow() {
        let rows = rows
        guard highlightedIndex >= 0, highlightedIndex < rows.count else { return }
        activate(rows[highlightedIndex])
    }

    private func activate(_ row: SessionSwitcherRow) {
        switch row.target {
        case .hostSession(let id):
            onSelectHostSession(id)
        case .workspace(let id):
            guard let workspace = workspacesByID[id] else { return }
            onSelectWorkspace(workspace)
        case .repo(let id):
            guard let repo = reposByID[id] else { return }
            onSelectRepo(repo)
        case .webSource(let id):
            guard let source = webSourcesByID[id] else { return }
            onSelectWebSource(source)
        case .command(.changeTerminalTheme):
            onOpenThemeSwitcher()
        }
    }
}

extension AgentKind {
    fileprivate var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .opencode: return "opencode"
        case .aider: return "Aider"
        case .unknown: return "Agent"
        }
    }
}

extension AwaitingReason {
    fileprivate var displayName: String {
        switch self {
        case .permissionPrompt: return "permission"
        case .idlePrompt: return "idle"
        case .custom: return "custom"
        }
    }
}
