//
//  SidebarInfoCard.swift
//  WorkspaceManager
//
//  Hover card for a sidebar item (repo root or workspace): the git branch, the
//  active agent's icon and run-state summary, and agent telemetry (model,
//  context, cost, last active). Styled to match WorkspaceCardView.
//

import SwiftUI
import WorkspaceManagerCore

struct SidebarInfoCard: View {
    let name: String
    var branch: String? = nil
    var agentStatus: AgentSessionStatus? = nil

    /// Whether the card would show anything beyond the name. When false the
    /// caller should skip the popover entirely — a name-only card is just noise.
    static func hasContent(branch: String?, agentStatus: AgentSessionStatus?) -> Bool {
        (branch?.isEmpty == false) || agentStatus != nil
    }

    private var trimmedBranch: String? {
        guard let branch, !branch.isEmpty else { return nil }
        return branch
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

            if let agentStatus {
                Divider()
                agentSection(agentStatus)
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
    private func agentSection(_ status: AgentSessionStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: status.kind.symbolName)
                    .foregroundStyle(status.kind.tintColor)
                    .frame(width: 16)
                Text(status.kind.displayName)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Circle()
                    .fill(SidebarSessionActivity.from(status).indicatorColor)
                    .frame(width: 6, height: 6)
                Text(status.run.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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
