//
//  SessionHistoryDetailView.swift
//  WorkspaceManager
//
//  Detail pane for a selected past session. Prefers the full Claude conversation
//  when its transcript still exists; falls back to the privacy-bounded event
//  timeline; and, when neither remains, explains that Claude prunes transcripts
//  while the local index outlives them.
//

import SwiftUI
import WorkspaceManagerCore

struct SessionHistoryDetailView: View {
    let item: SessionHistoryItem
    @ObservedObject var viewModel: SessionHistoryViewModel

    @State private var events: [AgentStatusEventRow] = []
    @State private var didLoadEvents = false

    var body: some View {
        Group {
            if let transcriptURL = item.transcriptURL {
                ConversationLogView(transcriptPath: transcriptURL)
            } else if !didLoadEvents {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !events.isEmpty {
                SessionHistoryEventTimelineView(events: events)
            } else {
                unavailable
            }
        }
        .task(id: item.id) {
            didLoadEvents = false
            events = []
            guard item.transcriptURL == nil else { return }
            events = await viewModel.events(for: item)
            didLoadEvents = true
        }
        .navigationTitle(item.title)
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.xmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Transcript no longer available")
                .font(.headline)
            Text(
                "The conversation for this session has been pruned. "
                    + "Claude removes old transcripts on its own schedule, while the local history index keeps the session record."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
