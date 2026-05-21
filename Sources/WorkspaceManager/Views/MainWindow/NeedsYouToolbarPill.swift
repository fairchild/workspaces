//
//  NeedsYouToolbarPill.swift
//  WorkspaceManager
//
//  Project-wide toolbar indicator that surfaces workspaces currently awaiting
//  input or errored. Reads from WorkspaceStatusAggregator so its count never
//  diverges from the bubbled dots in the sidebar.
//

import SwiftUI
import WorkspaceManagerCore

struct NeedsYouToolbarPill: View {
    @EnvironmentObject private var aggregator: WorkspaceStatusAggregator
    let repos: [Repo]
    let onActivate: (Workspace) -> Void

    var body: some View {
        if aggregator.attentionCount > 0, let firstAttentionWorkspace {
            Button {
                onActivate(firstAttentionWorkspace)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 7, height: 7)
                    Text("\(aggregator.attentionCount) need you")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.yellow.opacity(0.18))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.yellow.opacity(0.35), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help(tooltipText)
            .accessibilityLabel("\(aggregator.attentionCount) workspaces need attention")
        }
    }

    private var workspacesByID: [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: repos.flatMap(\.workspaces).map { ($0.id, $0) })
    }

    private var firstAttentionWorkspace: Workspace? {
        for id in aggregator.attentionWorkspaces {
            if let workspace = workspacesByID[id] {
                return workspace
            }
        }
        return nil
    }

    private var tooltipText: String {
        let names = aggregator.attentionWorkspaces
            .compactMap { workspacesByID[$0]?.name }
            .prefix(5)
        if names.isEmpty {
            return "\(aggregator.attentionCount) workspaces awaiting input or errored"
        }
        let remaining = aggregator.attentionCount - names.count
        let listed = names.joined(separator: ", ")
        if remaining > 0 {
            return "\(listed), and \(remaining) more"
        }
        return listed
    }
}
