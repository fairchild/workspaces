//
//  NeedsYouToolbarPill.swift
//  WorkspaceManager
//
//  Project-wide toolbar indicator that surfaces terminals currently awaiting
//  input or errored. Reads from WorkspaceStatusAggregator so its count never
//  diverges from the bubbled dots in the sidebar.
//

import SwiftUI
import WorkspaceManagerCore

struct NeedsYouToolbarPill: View {
    @EnvironmentObject private var aggregator: WorkspaceStatusAggregator
    let repos: [Repo]
    let onActivateWorkspace: (Workspace) -> Void
    let onActivateRepo: (Repo) -> Void

    var body: some View {
        if aggregator.attentionCount > 0, let firstAttentionTarget {
            Button {
                activate(firstAttentionTarget)
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
            .accessibilityLabel("\(aggregator.attentionCount) sessions need attention")
        }
    }

    private var reposByID: [UUID: Repo] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
    }

    private var workspacesByID: [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: repos.flatMap(\.workspaces).map { ($0.id, $0) })
    }

    private var firstAttentionTarget: WorkspaceStatusAggregator.AttentionTarget? {
        for target in aggregator.attentionTargets {
            switch target {
            case .workspace(let id):
                if workspacesByID[id] != nil { return target }
            case .repo(let id):
                if reposByID[id] != nil { return target }
            }
        }
        return nil
    }

    private func activate(_ target: WorkspaceStatusAggregator.AttentionTarget) {
        switch target {
        case .workspace(let id):
            guard let workspace = workspacesByID[id] else { return }
            onActivateWorkspace(workspace)
        case .repo(let id):
            guard let repo = reposByID[id] else { return }
            onActivateRepo(repo)
        }
    }

    private var tooltipText: String {
        let names = aggregator.attentionTargets
            .compactMap(displayName(for:))
            .prefix(5)
        if names.isEmpty {
            return "\(aggregator.attentionCount) sessions awaiting input or errored"
        }
        let remaining = aggregator.attentionCount - names.count
        let listed = names.joined(separator: ", ")
        if remaining > 0 {
            return "\(listed), and \(remaining) more"
        }
        return listed
    }

    private func displayName(for target: WorkspaceStatusAggregator.AttentionTarget) -> String? {
        switch target {
        case .workspace(let id):
            return workspacesByID[id]?.name
        case .repo(let id):
            guard let repo = reposByID[id] else { return nil }
            return "\(repo.name) repo"
        }
    }
}
