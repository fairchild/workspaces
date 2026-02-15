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
        .accessibilityLabel(isActiveSession ? "Active live terminal session" : "Live terminal session")
    }
}

struct HostTerminalRow: View {
    let defaultHostPath: String
    let hasLiveSession: Bool
    let isActiveSession: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActiveSession ? "house.fill" : "house")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Host Portfolio")
                    .lineLimit(1)

                Text(defaultHostPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if hasLiveSession {
                LiveSessionBadge(isActiveSession: isActiveSession)
                    .help(isActiveSession ? "Active live terminal session" : "Live terminal session")
            }
        }
        .accessibilityLabel("Host portfolio terminal")
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
                HStack(spacing: 6) {
                    Text(repo.name)
                        .lineLimit(1)

                    if hasLiveSession {
                        LiveSessionBadge(isActiveSession: isActiveSession)
                            .help(isActiveSession ? "Active live terminal session" : "Live terminal session")
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Text("\(repo.workspaces.count) workspace\(repo.workspaces.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if hasLiveSession {
                        Text(isActiveSession ? "active terminal" : "live terminal")
                            .font(.caption2)
                            .foregroundStyle(isActiveSession ? .green : .secondary)
                    }
                }
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
