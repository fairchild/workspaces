//
//  RestoreTargetIndexBuilder.swift
//  WorkspaceManager
//
//  Snapshots the current repos and non-archived workspaces into a Sendable
//  RestoreTargetIndex, so cold-start restore resolves persisted targets against
//  live data without carrying SwiftData models off the main actor. Uses the same
//  root-path derivation as the app's host-session key building.
//

import Foundation
import WorkspaceManagerCore

@MainActor
struct RestoreTargetIndexBuilder {
    let homeDirectoryPath: String
    let normalizePath: @Sendable (String) -> String

    func build(repos: [Repo]) -> RestoreTargetIndex {
        RestoreTargetIndex(
            homeDirectoryPath: homeDirectoryPath,
            repos: repos.map { repo in
                RestoreTargetIndex.Entry(
                    normalizedPath: normalizePath(repo.localPath),
                    rootPath: repo.localURL.path
                )
            },
            workspaces:
                repos
                .flatMap(\.workspaces)
                .filter { $0.status != .archived }
                .map { workspace in
                    RestoreTargetIndex.Entry(
                        normalizedPath: normalizePath(workspace.path),
                        rootPath: workspace.workspaceURL.path
                    )
                }
        )
    }
}
