//
//  SessionHistoryView.swift
//  WorkspaceManager
//
//  Standalone window browsing past coding sessions (durable-sessions epic).
//  Left: sessions grouped by day, newest first, loaded from the local history
//  index. Right: the selected session's conversation or event timeline.
//

import SwiftUI
import WorkspaceManagerCore

struct SessionHistoryView: View {
    static let windowID = "session-history"

    @StateObject private var viewModel: SessionHistoryViewModel
    @State private var selection: SessionHistoryItem.ID?

    init(store: LocalStateStore?) {
        _viewModel = StateObject(wrappedValue: SessionHistoryViewModel(store: store))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Session History")
                .frame(minWidth: 280)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { await viewModel.loadFirstPage() }
    }

    @ViewBuilder
    private var sidebar: some View {
        if viewModel.items.isEmpty {
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Sessions Yet",
                    systemImage: "clock",
                    description: Text("Terminal sessions you open will appear here.")
                )
            }
        } else {
            List(selection: $selection) {
                ForEach(viewModel.sections) { section in
                    Section(Self.sectionTitle(section.id)) {
                        ForEach(section.items) { item in
                            SessionHistoryListRow(item: item).tag(item.id)
                        }
                    }
                }
                if viewModel.canLoadMore {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .task { await viewModel.loadMore() }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let item = viewModel.items.first(where: { $0.id == selection }) {
            SessionHistoryDetailView(item: item, viewModel: viewModel)
        } else {
            ContentUnavailableView(
                "Select a Session",
                systemImage: "sidebar.left",
                description: Text("Pick a session to read its conversation.")
            )
        }
    }

    static func sectionTitle(_ day: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}
