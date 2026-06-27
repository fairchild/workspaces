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
    @State private var isDropdownPresented = false
    let repos: [Repo]
    let onActivateWorkspace: (Workspace) -> Void
    let onActivateRepo: (Repo) -> Void

    var body: some View {
        let items = resolvedAttentionItems
        let attentionCount = items.count
        if !items.isEmpty {
            Button {
                isDropdownPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentChromeProjection.attentionTone.color)
                    Text("\(attentionCount) need you")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(AgentChromeProjection.attentionTone.color.opacity(0.18))
                )
                .overlay(
                    Capsule()
                        .stroke(AgentChromeProjection.attentionTone.color.opacity(0.35), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help(tooltipText(for: items))
            .accessibilityLabel("\(attentionCount) sessions need attention")
            .popover(isPresented: $isDropdownPresented, arrowEdge: .top) {
                NeedsYouDropdown(
                    items: items,
                    onSelect: { item in
                        isDropdownPresented = false
                        activate(item.target)
                    }
                )
            }
        }
    }

    private var resolvedAttentionItems: [AttentionSummaryItem] {
        AttentionSummaryResolver.resolve(attentionItems: aggregator.attentionItems, repos: repos)
    }

    private var reposByID: [UUID: Repo] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
    }

    private var workspacesByID: [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: repos.flatMap(\.workspaces).map { ($0.id, $0) })
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

    private func tooltipText(for items: [AttentionSummaryItem]) -> String {
        let names = items.map(\.title).prefix(5)
        if names.isEmpty {
            return AgentChromeProjection.attentionTooltipFallback(count: items.count)
        }
        let remaining = items.count - names.count
        let listed = names.joined(separator: ", ")
        if remaining > 0 {
            return "\(listed), and \(remaining) more"
        }
        return listed
    }
}

private struct NeedsYouDropdown: View {
    let items: [AttentionSummaryItem]
    let onSelect: (AttentionSummaryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Needs You")
                    .font(.headline)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            NeedsYouDropdownRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 320)
    }
}

private struct NeedsYouDropdownRow: View {
    let item: AttentionSummaryItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.isError ? .red : .yellow)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(item.badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.isError ? .red : .yellow)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill((item.isError ? Color.red : Color.yellow).opacity(0.14))
                        )
                }

                Text("\(item.detail) - \(item.context)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.001))
        )
    }
}
