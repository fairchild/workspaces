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
                                SessionSwitcherRowView(row: row, isHighlighted: index == highlightedIndex)
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

    private func rowBackground(isHighlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
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

/// One switcher card: icon + live-activity dot, title/kind, subtitle, the status-derived
/// activity snippet (`row.preview`), and the metadata chip row. Extracted from the List so it
/// renders standalone (SwiftUI `List` does not draw its rows under `ImageRenderer`).
struct SessionSwitcherRowView: View {
    let row: SessionSwitcherRow
    var isHighlighted: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: iconName)
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
                    .foregroundStyle(row.activity.emphasizesPreview ? .primary : .secondary)
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

    private var iconName: String {
        switch row.kind {
        case .workspace: return "terminal"
        case .repo: return "folder"
        case .terminal: return "rectangle.terminal"
        case .web: return "globe"
        case .command: return "command"
        }
    }
}
