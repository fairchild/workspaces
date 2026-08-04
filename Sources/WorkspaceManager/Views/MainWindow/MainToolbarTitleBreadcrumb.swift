//
//  MainToolbarTitleBreadcrumb.swift
//  WorkspaceManager
//
//  The principal toolbar's repo/workspace breadcrumb: a repo icon and name that open the repo
//  overview and its terminal, with the selected workspace trailing.
//

import SwiftUI
import WorkspaceManagerCore

struct MainToolbarTitleBreadcrumb: View {
    let title: MainWindowToolbarTitle
    let faviconSource: WebSource?
    let onOpenRepoOverview: () -> Void
    let onOpenRepoTerminal: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onOpenRepoOverview) {
                repoIcon
            }
            .buttonStyle(.plain)
            .help("Open Repo Overview")
            .accessibilityLabel("Open Repo Overview")
            .accessibilityIdentifier("main-toolbar.repo-overview")

            Button(action: onOpenRepoTerminal) {
                Text(title.repoName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open \(title.repoName) Terminal")
            .accessibilityIdentifier("main-toolbar.repo-terminal")

            if let workspaceName = title.workspaceName {
                Text("/")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(workspaceName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("main-toolbar.workspace-title")
            }
        }
        .frame(maxWidth: 360)
        .accessibilityIdentifier("main-toolbar.title")
    }

    @ViewBuilder
    private var repoIcon: some View {
        if let faviconSource {
            WebSourceFaviconView(source: faviconSource)
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}
