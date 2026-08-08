//
//  UIFixtureOrphanBannerBootstrap.swift
//  WorkspaceManager
//
//  Fixture-mode staging for the workspace-orphan cleanup banner. The real banner is fed
//  by a filesystem scan, which on a dev machine can surface genuine leftovers — noise
//  that would make fixture captures (and their ui-state goldens) machine-dependent. In
//  fixture mode the scan is replaced wholesale: a deterministic synthetic item when the
//  orphan-banner scenario asks for one, an empty result otherwise.
//
//  Debug-only, following #1235/#1237: the release build carries the release stub, so the
//  arming env key never reaches a release binary and there is no way to substitute the
//  scan there. `scripts/check-release-harness-absence.sh` enforces that absence.
//

import Foundation
import WorkspaceManagerCore

enum UIFixtureOrphanBannerBootstrap {
    #if DEBUG
        static let seedEnvKey = "WORKSPACES_UI_FIXTURE_SEED_ORPHAN_BANNER"

        /// The scan result fixture mode substitutes for the real filesystem scan: synthetic
        /// items when seeding is requested, `[]` for every other fixture launch (keeping the
        /// `clean` golden deterministic), `nil` outside fixture mode (real scan proceeds).
        static func fixtureScanResult(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> [WorkspaceOrphanItem]? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
            guard environment[seedEnvKey] == "1" else { return [] }
            return [syntheticItem(homeDirectory: homeDirectory)]
        }

        /// A stray git worktree under the fixture's bertram-chat repo — the most common real
        /// orphan shape. Stable id and names so the banner's rendered copy never varies.
        static func syntheticItem(homeDirectory: URL) -> WorkspaceOrphanItem {
            let repoPath =
                homeDirectory
                .appendingPathComponent("code", isDirectory: true)
                .appendingPathComponent("bertram-chat", isDirectory: true)
            let worktreePath =
                homeDirectory
                .appendingPathComponent("code", isDirectory: true)
                .appendingPathComponent("workspaces", isDirectory: true)
                .appendingPathComponent("bertram-chat", isDirectory: true)
                .appendingPathComponent("stale-experiment", isDirectory: true)
            return WorkspaceOrphanItem(
                id: "fixture:git-worktree:stale-experiment",
                kind: .gitWorktreeWithoutRecord,
                repoID: nil,
                repoName: "bertram-chat",
                repoLocalPath: repoPath.path,
                workspaceID: nil,
                workspaceName: nil,
                resourceName: "stale-experiment",
                path: worktreePath.path,
                storagePath: nil,
                gitBranch: "workspace/stale-experiment",
                hasPrunableGitMetadata: true
            )
        }
    #else
        /// Release stub: no substitution, so the real filesystem scan always proceeds.
        static func fixtureScanResult(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> [WorkspaceOrphanItem]? { nil }
    #endif
}
