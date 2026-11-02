//
//  UIFixtureOrphanBannerBootstrap.swift
//  WorkspaceManager
//
//  Fixture-mode staging for the workspace-orphan cleanup banner. The real banner is fed
//  by a filesystem scan, which on a dev machine can surface genuine leftovers — noise
//  that would make fixture captures (and their ui-state goldens) machine-dependent. In
//  fixture mode the scan is replaced wholesale: a deterministic synthetic item when the
//  orphan-banner scenario asks for one, an empty result otherwise. The
//  orphan-banner-overflow scenario seeds a long list and opens it, staging the state
//  where an unbounded list once pushed the banner's header under the title bar (#1829).
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

        /// `overflow` seeds this many leftovers: the count from the report that found the
        /// unbounded list, and more than a 900pt window can show without scrolling.
        static let overflowItemCount = 19

        /// The scan result fixture mode substitutes for the real filesystem scan: synthetic
        /// items when seeding is requested (`1` for one, `overflow` for a long list), `[]` for
        /// every other fixture launch (keeping the `clean` golden deterministic), `nil`
        /// outside fixture mode (real scan proceeds).
        static func fixtureScanResult(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> [WorkspaceOrphanItem]? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
            switch environment[seedEnvKey] {
            case "1":
                return [syntheticItem(homeDirectory: homeDirectory)]
            case "overflow":
                return (1...overflowItemCount).map {
                    syntheticItem(homeDirectory: homeDirectory, name: "stale-experiment-\($0)")
                }
            default:
                return []
            }
        }

        /// Whether the banner opens with its list expanded: only for the overflow seed, whose
        /// point is the expanded list's height.
        static func startsExpanded(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool {
            environment["WORKSPACES_UI_FIXTURE"] == "1" && environment[seedEnvKey] == "overflow"
        }

        /// A stray git worktree under the fixture's bertram-chat repo — the most common real
        /// orphan shape. Stable id and names so the banner's rendered copy never varies.
        static func syntheticItem(
            homeDirectory: URL,
            name: String = "stale-experiment"
        ) -> WorkspaceOrphanItem {
            let repoPath =
                homeDirectory
                .appendingPathComponent("code", isDirectory: true)
                .appendingPathComponent("bertram-chat", isDirectory: true)
            let worktreePath =
                homeDirectory
                .appendingPathComponent("code", isDirectory: true)
                .appendingPathComponent("workspaces", isDirectory: true)
                .appendingPathComponent("bertram-chat", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            return WorkspaceOrphanItem(
                id: "fixture:git-worktree:\(name)",
                kind: .gitWorktreeWithoutRecord,
                repoID: nil,
                repoName: "bertram-chat",
                repoLocalPath: repoPath.path,
                workspaceID: nil,
                workspaceName: nil,
                resourceName: name,
                path: worktreePath.path,
                storagePath: nil,
                gitBranch: "workspace/\(name)",
                hasPrunableGitMetadata: true
            )
        }
    #else
        /// Release stub: no substitution, so the real filesystem scan always proceeds.
        static func fixtureScanResult(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> [WorkspaceOrphanItem]? { nil }

        static func startsExpanded(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool { false }
    #endif
}
