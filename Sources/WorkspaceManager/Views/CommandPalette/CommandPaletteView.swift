//
//  CommandPaletteView.swift
//  WorkspaceManager
//
//  ⌘P switcher — fuzzy-find a workspace, repo, or web source and activate it
//  with one keystroke. Reads status dots from WorkspaceStatusAggregator.
//

import SwiftUI
import WorkspaceManagerCore

/// A non-navigational command surfaced in the palette (e.g. "Change Terminal
/// Theme…"). Seeds the switcher with actions, distinct from items you switch to.
private struct CommandPaletteAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let perform: () -> Void
}

private enum PaletteRow: SwitchableItem {
    case workspace(WorkspaceSwitchableItem)
    case repo(RepoSwitchableItem)
    case web(WebSourceSwitchableItem)
    case command(CommandPaletteAction)

    var id: String {
        switch self {
        case .workspace(let item): return "ws-\(item.id.uuidString)"
        case .repo(let item): return "repo-\(item.id.uuidString)"
        case .web(let item): return "web-\(item.id.uuidString)"
        case .command(let action): return "cmd-\(action.id)"
        }
    }

    var title: String {
        switch self {
        case .workspace(let item): return item.title
        case .repo(let item): return item.title
        case .web(let item): return item.title
        case .command(let action): return action.title
        }
    }

    var subtitle: String {
        switch self {
        case .workspace(let item): return item.subtitle
        case .repo(let item): return item.subtitle
        case .web(let item): return item.subtitle
        case .command(let action): return action.subtitle
        }
    }

    var indicator: SidebarSessionActivity {
        switch self {
        case .workspace(let item): return item.indicator
        case .repo(let item): return item.indicator
        case .web(let item): return item.indicator
        case .command: return .inactive
        }
    }

    var sortKey: Date {
        switch self {
        case .workspace(let item): return item.sortKey
        case .repo(let item): return item.sortKey
        case .web(let item): return item.sortKey
        // Pin commands above recency-sorted items on an empty query.
        case .command: return .distantFuture
        }
    }

    func matches(_ query: String) -> Bool {
        switch self {
        case .workspace(let item): return item.matches(query)
        case .repo(let item): return item.matches(query)
        case .web(let item): return item.matches(query)
        case .command(let action):
            guard !query.isEmpty else { return true }
            return action.title.localizedCaseInsensitiveContains(query)
                || action.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    func activate(_ context: SwitchableContext) {
        switch self {
        case .workspace(let item): item.activate(context)
        case .repo(let item): item.activate(context)
        case .web(let item): item.activate(context)
        case .command(let action): action.perform()
        }
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject private var aggregator: WorkspaceStatusAggregator
    let repos: [Repo]
    let webSources: [WebSource]
    let workspaceActivities: [UUID: SidebarSessionActivity]
    let repoActivities: [UUID: SidebarSessionActivity]
    let onSelectWorkspace: (Workspace) -> Void
    let onSelectRepo: (Repo) -> Void
    let onSelectWebSource: (WebSource) -> Void
    let onDismiss: () -> Void
    let onOpenThemeSwitcher: () -> Void

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var queryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            queryField
            Divider()
            resultsList
        }
        .frame(width: 560, height: 420)
        .background(.thinMaterial)
        .onAppear {
            queryFieldFocused = true
        }
    }

    private var queryField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search workspaces, repos, web sources", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($queryFieldFocused)
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
        let rows = filteredRows
        return Group {
            if rows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            paletteRowView(row, isHighlighted: index == highlightedIndex)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    highlightedIndex = index
                                    activate(row)
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(
                                            index == highlightedIndex
                                                ? Color.accentColor.opacity(0.18)
                                                : Color.clear
                                        )
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                )
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
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "Nothing to switch to yet." : "No results for “\(query)”")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func paletteRowView(_ row: PaletteRow, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: row))
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout.weight(isHighlighted ? .semibold : .regular))
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.indicator.hasLiveSession {
                Circle()
                    .fill(row.indicator.indicatorColor)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private func iconName(for row: PaletteRow) -> String {
        switch row {
        case .workspace: return "terminal"
        case .repo: return "folder"
        case .web: return "globe"
        case .command(let action): return action.systemImage
        }
    }

    private var filteredRows: [PaletteRow] {
        let workspaceRows: [PaletteRow] = repos.flatMap(\.workspaces).map { workspace in
            let status = aggregator.workspaceStatuses[workspace.id]
            return PaletteRow.workspace(
                WorkspaceSwitchableItem(
                    workspace: workspace,
                    indicator: workspaceActivities[workspace.id] ?? SidebarSessionActivity.from(status),
                    waitingDescriptor: waitingDescriptor(for: status?.run)
                )
            )
        }
        let repoRows: [PaletteRow] = repos.map { repo in
            let status = aggregator.repoStatuses[repo.id]
            return PaletteRow.repo(
                RepoSwitchableItem(
                    repo: repo,
                    indicator: repoActivities[repo.id] ?? SidebarSessionActivity.from(status)
                )
            )
        }
        let webRows: [PaletteRow] = webSources.map { source in
            .web(WebSourceSwitchableItem(source: source))
        }
        let commandRows: [PaletteRow] = [
            .command(
                CommandPaletteAction(
                    id: "change-terminal-theme",
                    title: "Change Terminal Theme…",
                    subtitle: "Command · ⇧⌘P",
                    systemImage: "paintpalette",
                    perform: onOpenThemeSwitcher
                )
            )
        ]
        return SwitchableIndex.rank(commandRows + workspaceRows + repoRows + webRows, query: query)
    }

    private func waitingDescriptor(for state: AgentRunState?) -> String? {
        guard let state else { return nil }
        return AgentChromeProjection.runState(state).commandPaletteDescriptor
    }

    private func moveHighlight(by delta: Int) {
        let rows = filteredRows
        guard !rows.isEmpty else { return }
        let next = max(0, min(rows.count - 1, highlightedIndex + delta))
        highlightedIndex = next
    }

    private func activateHighlightedRow() {
        let rows = filteredRows
        guard highlightedIndex >= 0, highlightedIndex < rows.count else { return }
        activate(rows[highlightedIndex])
    }

    private func activate(_ row: PaletteRow) {
        let context = SwitchableContext(
            selectWorkspace: onSelectWorkspace,
            selectRepo: onSelectRepo,
            selectWebSource: onSelectWebSource
        )
        row.activate(context)
    }
}
