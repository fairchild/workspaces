//
//  SidebarRows.swift
//  WorkspaceManager
//
//  Row views for the sidebar list
//

import SwiftUI
import WorkspaceManagerCore

private struct LiveSessionBadge: View {
    let isActiveSession: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isActiveSession ? "terminal.fill" : "terminal")
                .font(.caption2)

            if isActiveSession {
                Text("LIVE")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(isActiveSession ? .green : .secondary)
        .background(
            Capsule()
                .fill(isActiveSession ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15))
        )
    }
}

struct RepositoriesSectionHeaderView: View {
    let defaultHostPath: String
    let hasLiveSession: Bool
    let isActiveSession: Bool
    let onActivateHost: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Repositories")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button(action: onActivateHost) {
                HStack(spacing: 6) {
                    Image(systemName: isActiveSession ? "house.fill" : "house")
                    Text("Host")
                        .fontWeight(.semibold)

                    if hasLiveSession {
                        Image(systemName: isActiveSession ? "terminal.fill" : "terminal")
                            .foregroundStyle(isActiveSession ? .green : .secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .help("Open host terminal at \(defaultHostPath)")

            if hasLiveSession {
                LiveSessionBadge(isActiveSession: isActiveSession)
                    .help(isActiveSession ? "Active live terminal session" : "Live terminal session")
            }
        }
    }
}

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
                LiveSessionBadge(isActiveSession: isActiveSession)
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
