//
//  SidebarRows.swift
//  WorkspaceManager
//
//  Row views for the sidebar list
//

import SwiftUI
import WorkspaceManagerCore

struct RepoRow: View {
    let repo: Repo
    let hasLiveSession: Bool
    let isActiveSession: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .lineLimit(1)

                Text("\(repo.workspaces.count) workspace\(repo.workspaces.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if hasLiveSession {
                Image(systemName: isActiveSession ? "terminal.fill" : "terminal")
                    .font(.caption)
                    .foregroundStyle(isActiveSession ? .green : .secondary)
                    .help(isActiveSession ? "Active live terminal session" : "Live terminal session")
            }
        }
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(workspace.name)
                        .lineLimit(1)

                    if workspace.status == .archived {
                        Text("Archived")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                if let branch = workspace.gitBranch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                        Text(branch)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "terminal.fill")
                .foregroundStyle(workspace.status == .active ? .green : .secondary)
        }
    }
}
