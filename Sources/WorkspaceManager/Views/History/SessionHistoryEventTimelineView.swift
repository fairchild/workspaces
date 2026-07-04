//
//  SessionHistoryEventTimelineView.swift
//  WorkspaceManager
//
//  Fallback detail for a past session whose Claude transcript is gone (pruned):
//  the privacy-bounded event timeline the local store retained — coarse markers
//  only, no prompts or tool payloads.
//

import SwiftUI
import WorkspaceManagerCore

struct SessionHistoryEventTimelineView: View {
    let events: [AgentStatusEventRow]

    var body: some View {
        List(events) { event in
            HStack(spacing: 10) {
                Text(event.eventAt, format: .dateTime.hour().minute().second())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label(for: event))
                        .font(.callout)
                    if let detail = event.toolName ?? event.awaitingReason ?? event.errorCategory {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(event.runState)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 1)
        }
        .listStyle(.inset)
    }

    private func label(for event: AgentStatusEventRow) -> String {
        event.eventName.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
