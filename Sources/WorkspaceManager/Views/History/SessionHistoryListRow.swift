//
//  SessionHistoryListRow.swift
//  WorkspaceManager
//
//  One row in the session history list: the session's directory, when it last
//  ran, its model, and whether its Claude transcript is still resumable.
//

import SwiftUI

struct SessionHistoryListRow: View {
    let item: SessionHistoryItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isResumable ? "bubble.left.and.text.bubble.right" : "clock")
                .foregroundStyle(item.isResumable ? Color.accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(item.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.timestamp, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let model = item.modelDisplayName {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
