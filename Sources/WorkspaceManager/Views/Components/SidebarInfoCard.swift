//
//  SidebarInfoCard.swift
//  WorkspaceManager
//
//  Hover card for a sidebar item (repo root or workspace): the git branch and a
//  one-line summary of each open terminal tab — agent tabs show the agent icon
//  and run state, plain tabs show their real foreground process (tmux mode) or fall
//  back to the terminal title. When a single agent is running, its telemetry (model,
//  context, cost, last active) is shown too. Styled to match WorkspaceCardView.
//

import SwiftUI
import WorkspaceManagerCore

/// One terminal tab/pane of a sidebar row. `title` is the tab's display title
/// (the running program's terminal title, a user override, or the directory);
/// `agentStatus` is set when that tab is running a known agent.
struct SidebarTabSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    var agentStatus: AgentSessionStatus? = nil
    /// Last assistant message from the agent's transcript, resolved lazily when the hover
    /// card opens (Claude Code only; `nil` for every non-happy path). See #680.
    var transcriptTail: String? = nil
}

struct SidebarInfoCard: View {
    let name: String
    var branch: String? = nil
    var tabs: [SidebarTabSummary] = []

    /// Whether the card would show anything beyond the name. When false the
    /// caller should skip the popover entirely — a name-only card is just noise.
    /// A lone plain tab whose title equals the row name adds nothing.
    static func hasContent(name: String, branch: String?, tabs: [SidebarTabSummary]) -> Bool {
        if branch?.isEmpty == false { return true }
        if tabs.contains(where: { $0.agentStatus != nil }) { return true }
        if tabs.count > 1 { return true }
        if let only = tabs.first { return only.title != name }
        return false
    }

    private var trimmedBranch: String? {
        guard let branch, !branch.isEmpty else { return nil }
        return branch
    }

    /// The single tab running an agent, if exactly one does — used to surface its telemetry
    /// (and latest transcript message) without crowding the card when several agents run.
    private var soleAgentTab: SidebarTabSummary? {
        let agentTabs = tabs.filter { $0.agentStatus != nil }
        return agentTabs.count == 1 ? agentTabs.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            if let trimmedBranch {
                Label(trimmedBranch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !tabs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tabs) { tabRow($0) }
                }
            }

            if let soleAgentTab, let agent = soleAgentTab.agentStatus {
                Divider()
                agentDetails(agent)
                if let tail = soleAgentTab.transcriptTail, !tail.isEmpty {
                    Text(tail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Latest message: \(tail)")
                }
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func tabRow(_ tab: SidebarTabSummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tab.agentStatus?.kind.symbolName ?? "terminal")
                .foregroundStyle(tab.agentStatus?.kind.tintColor ?? Color.secondary)
                .frame(width: 16)
            Text(tab.title)
                .font(.caption)
                .lineLimit(1)
            if let agent = tab.agentStatus {
                Spacer(minLength: 8)
                Circle()
                    .fill(SidebarSessionActivity.from(agent).indicatorColor)
                    .frame(width: 6, height: 6)
                Text(agent.run.summaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Spacer(minLength: 8)
            }
        }
    }

    @ViewBuilder
    private func agentDetails(_ status: AgentSessionStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let model = status.modelDisplayName, !model.isEmpty {
                detailRow("Model") { Text(model) }
            }
            if let context = status.contextUsedPercent {
                detailRow("Context") { Text("\(Int(context.rounded()))%") }
            }
            if let cost = status.costUSD {
                detailRow("Cost") { Text(String(format: "$%.2f", cost)) }
            }
            detailRow("Last active") { Text(status.lastEventAt, style: .relative) }
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, @ViewBuilder _ value: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            value()
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
