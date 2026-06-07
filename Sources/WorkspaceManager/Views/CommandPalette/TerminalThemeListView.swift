//
//  TerminalThemeListView.swift
//  WorkspaceManager
//
//  Searchable theme list shared by the Settings pickers and the Cmd+Shift+P
//  command overlay. Featured themes are pinned on top when the query is empty;
//  typing collapses the list into a single ranked result set. Highlighting a
//  row previews it live (the host debounces); Enter commits, Esc cancels.
//

import SwiftUI

struct TerminalThemeListView: View {
    let allThemes: [GhosttyTheme]
    let featuredThemes: [GhosttyTheme]
    /// Recently committed theme names, most-recent-first. Pinned in a "Recent"
    /// section above Featured so the last-used themes are an arrow-key away.
    var recentThemes: [String] = []
    /// Currently committed name for the slot being edited ("" = Ghostty default).
    let currentSelectionName: String
    /// Whether to offer a "Ghostty Default" row that clears the slot.
    let showsDefaultRow: Bool
    /// Live preview of a candidate ("" = default). Called as the highlight moves.
    let onPreview: (String) -> Void
    /// Commit a candidate ("" = default).
    let onCommit: (String) -> Void
    /// Revert any preview and dismiss without committing.
    let onCancel: () -> Void

    @State private var query = ""
    @State private var highlightedID: String?
    @FocusState private var searchFocused: Bool

    private static let defaultEntryID = "__ghostty_default__"

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .onAppear {
            searchFocused = true
            highlightedID = initialHighlightID
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search themes", text: $query)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($searchFocused)
                .onSubmit { commitHighlighted() }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onCancel()
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onChange(of: query) { _, _ in
            highlightedID = orderedSelectableIDs.first
            previewHighlighted()
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsList: some View {
        let sections = displaySections
        if sections.allSatisfy({ $0.themes.isEmpty }) && !sections.contains(where: { $0.includesDefault }) {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(sections) { section in
                        Section {
                            if section.includesDefault {
                                themeRow(
                                    id: Self.defaultEntryID,
                                    title: "Ghostty Default",
                                    systemImage: "circle.dashed",
                                    isCurrent: currentSelectionName.isEmpty,
                                    name: ""
                                )
                            }
                            ForEach(section.themes) { theme in
                                themeRow(
                                    id: theme.id,
                                    title: theme.name,
                                    systemImage: "paintpalette",
                                    isCurrent: theme.name == currentSelectionName,
                                    name: theme.name
                                )
                            }
                        } header: {
                            if let title = section.header {
                                Text(title)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlightedID) { _, newValue in
                    guard let newValue else { return }
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "paintpalette")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No themes match “\(query)”")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func themeRow(
        id: String,
        title: String,
        systemImage: String,
        isCurrent: Bool,
        name: String
    ) -> some View {
        let isHighlighted = id == highlightedID
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .frame(width: 18)
            Text(title)
                .font(.callout.weight(isHighlighted ? .semibold : .regular))
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .id(id)
        .onTapGesture {
            highlightedID = id
            onCommit(name)
        }
        .onHover { hovering in
            if hovering, highlightedID != id {
                highlightedID = id
                onPreview(name)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        )
    }

    // MARK: Section model

    private struct DisplaySection: Identifiable {
        let id: String
        let header: String?
        let includesDefault: Bool
        let themes: [GhosttyTheme]
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displaySections: [DisplaySection] {
        guard trimmedQuery.isEmpty else {
            return [
                DisplaySection(
                    id: "results",
                    header: nil,
                    includesDefault: false,
                    themes: GhosttyThemeCatalog.rank(allThemes, query: query)
                )
            ]
        }

        // Recent first (most-recent-first), then Featured, then everything else.
        // A theme appears in exactly one section so row IDs stay unique.
        let byName = Dictionary(allThemes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var recent: [GhosttyTheme] = []
        var recentSeen = Set<String>()
        for name in recentThemes {
            guard let theme = byName[name], !recentSeen.contains(name) else { continue }
            recentSeen.insert(name)
            recent.append(theme)
        }

        let featured = featuredThemes.filter { !recentSeen.contains($0.name) }
        let excluded = recentSeen.union(featured.map(\.name))
        let rest = allThemes.filter { !excluded.contains($0.name) }

        var sections: [DisplaySection] = []
        if !recent.isEmpty {
            sections.append(
                DisplaySection(id: "recent", header: "Recent", includesDefault: false, themes: recent)
            )
        }
        sections.append(
            DisplaySection(id: "featured", header: "Featured", includesDefault: showsDefaultRow, themes: featured)
        )
        sections.append(
            DisplaySection(id: "all", header: "All Themes", includesDefault: false, themes: rest)
        )
        return sections
    }

    /// Selectable row IDs in display order — drives arrow navigation.
    private var orderedSelectableIDs: [String] {
        displaySections.flatMap { section -> [String] in
            (section.includesDefault ? [Self.defaultEntryID] : []) + section.themes.map(\.id)
        }
    }

    private var initialHighlightID: String? {
        let ids = orderedSelectableIDs
        // Prefer the most-recently-used theme so it's a single arrow press away.
        if let firstRecent = ids.first(where: { recentThemes.contains($0) }) {
            return firstRecent
        }
        if !currentSelectionName.isEmpty, ids.contains(currentSelectionName) {
            return currentSelectionName
        }
        if currentSelectionName.isEmpty, showsDefaultRow {
            return Self.defaultEntryID
        }
        return ids.first
    }

    private func name(forID id: String) -> String {
        id == Self.defaultEntryID ? "" : id
    }

    // MARK: Navigation

    private func moveHighlight(by delta: Int) {
        let ids = orderedSelectableIDs
        guard !ids.isEmpty else { return }
        let currentIndex = highlightedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let nextIndex = max(0, min(ids.count - 1, currentIndex + delta))
        highlightedID = ids[nextIndex]
        previewHighlighted()
    }

    private func previewHighlighted() {
        guard let highlightedID else { return }
        onPreview(name(forID: highlightedID))
    }

    private func commitHighlighted() {
        guard let highlightedID else { return }
        onCommit(name(forID: highlightedID))
    }
}
