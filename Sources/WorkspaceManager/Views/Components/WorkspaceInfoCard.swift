//
//  WorkspaceInfoCard.swift
//  WorkspaceManager
//
//  Hover card for a sidebar workspace row: branch, the active agent's icon and
//  run-state summary, and agent telemetry (model, context, cost, last active).
//  Styled to match WorkspaceCardView so the popover feels native.
//

import SwiftUI
import WorkspaceManagerCore

struct WorkspaceInfoCard: View {
    let workspace: Workspace
    var agentStatus: AgentSessionStatus? = nil

    private var branch: String? {
        guard let branch = workspace.gitBranch, !branch.isEmpty else { return nil }
        return branch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            if let branch {
                Label(branch, systemImage: "arrow.triangle.branch")
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
                detailRow("Model", model)
            }
            if let context = status.contextUsedPercent {
                detailRow("Context", "\(Int(context.rounded()))%")
            }
            if let cost = status.costUSD {
                detailRow("Cost", String(format: "$%.2f", cost))
            }
            detailRow("Last active", relativeLastActive(status.lastEventAt))
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func relativeLastActive(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
