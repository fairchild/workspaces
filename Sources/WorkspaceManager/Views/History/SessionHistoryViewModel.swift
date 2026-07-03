//
//  SessionHistoryViewModel.swift
//  WorkspaceManager
//
//  Loads the session history index from the local state store (newest-first,
//  paginated), maps rows to display items, and lazily fetches a session's
//  privacy-bounded event timeline on selection. Reads only the SQLite sidecar —
//  it renders titles from the stored path strings, not live SwiftData.
//

import Foundation
import WorkspaceManagerCore

@MainActor
final class SessionHistoryViewModel: ObservableObject {
    @Published private(set) var items: [SessionHistoryItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var canLoadMore = true

    private let store: LocalStateStore?
    private let resumability: ClaudeTranscriptResumability
    private let pageSize: Int
    private var offset = 0

    init(
        store: LocalStateStore?,
        resumability: ClaudeTranscriptResumability = ClaudeTranscriptResumability(),
        pageSize: Int = 50
    ) {
        self.store = store
        self.resumability = resumability
        self.pageSize = max(1, pageSize)
    }

    var sections: [SessionHistoryDaySection] { SessionHistoryGrouping.byDay(items) }

    func loadFirstPage() async {
        items = []
        offset = 0
        canLoadMore = true
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, canLoadMore, let store else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await store.fetchContinuitySessions(activeOnly: false, limit: pageSize, offset: offset)
            let page = rows.map { SessionHistoryItem.make(from: $0, resumability: resumability) }
            items.append(contentsOf: page)
            offset += rows.count
            canLoadMore = rows.count == pageSize
            loadError = nil
        } catch {
            loadError = String(describing: error)
            canLoadMore = false
        }
    }

    /// The session's event timeline in chronological order (the store returns
    /// newest-first). Empty when there are no events or no store.
    func events(for item: SessionHistoryItem) async -> [AgentStatusEventRow] {
        guard let store else { return [] }
        let rows = (try? await store.fetchAgentStatusEvents(hostSessionID: item.id)) ?? []
        return rows.reversed()
    }
}
