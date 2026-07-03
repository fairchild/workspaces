//
//  TerminalRestoreTargetResolver.swift
//  WorkspaceManagerCore
//
//  Resolves a persisted continuity row to a live restore target, conservatively:
//  a row restores only when its repo/workspace still exists in current data.
//  Operates over a Sendable snapshot of paths (RestoreTargetIndex) rather than
//  live SwiftData models, so resolution stays pure and container-free to test;
//  the app target builds the snapshot from its ModelContext in a later slice.
//

import Foundation

/// A Sendable snapshot of the paths a restore can resolve against. Workspaces are
/// pre-filtered to non-archived by the builder.
public struct RestoreTargetIndex: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let normalizedPath: String
        public let rootPath: String

        public init(normalizedPath: String, rootPath: String) {
            self.normalizedPath = normalizedPath
            self.rootPath = rootPath
        }
    }

    public let homeDirectoryPath: String
    public let repos: [Entry]
    public let workspaces: [Entry]

    public init(homeDirectoryPath: String, repos: [Entry], workspaces: [Entry]) {
        self.homeDirectoryPath = homeDirectoryPath
        self.repos = repos
        self.workspaces = workspaces
    }
}

/// Maps a continuity row to a `ResolvedRestoreTarget`, or `nil` to drop it
/// (missing repo/workspace, or a conservatively-excluded backend session).
public struct TerminalRestoreTargetResolver: Sendable {
    private let index: RestoreTargetIndex
    private let normalizePath: @Sendable (String) -> String

    public init(
        index: RestoreTargetIndex,
        normalizePath: @escaping @Sendable (String) -> String = TerminalRestoreTargetResolver.defaultNormalizePath
    ) {
        self.index = index
        self.normalizePath = normalizePath
    }

    public func resolve(_ row: TerminalSessionContinuityRow) -> ResolvedRestoreTarget? {
        switch row.targetKind {
        case "default_home":
            return ResolvedRestoreTarget(
                key: .defaultHome,
                rootDirectory: URL(fileURLWithPath: index.homeDirectoryPath)
            )
        case "repo":
            guard let entry = match(row.targetPath, in: index.repos) else { return nil }
            return ResolvedRestoreTarget(
                key: .repoPath(entry.rootPath),
                rootDirectory: URL(fileURLWithPath: entry.rootPath)
            )
        case "host_path":
            guard let entry = match(row.targetPath, in: index.workspaces) else { return nil }
            return ResolvedRestoreTarget(
                key: .hostPath(entry.rootPath),
                rootDirectory: URL(fileURLWithPath: entry.rootPath)
            )
        default:
            // backend_session (remote) and any unknown kind are dropped.
            return nil
        }
    }

    /// Adapt to the planner's injected `TargetResolver` closure.
    public func asResolver() -> TerminalRestorePlanner.TargetResolver {
        { row in resolve(row) }
    }

    private func match(_ targetPath: String?, in entries: [RestoreTargetIndex.Entry]) -> RestoreTargetIndex.Entry? {
        guard let targetPath, !targetPath.isEmpty else { return nil }
        let normalized = normalizePath(targetPath)
        return entries.first { $0.normalizedPath == normalized }
    }

    public static let defaultNormalizePath: @Sendable (String) -> String = { path in
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
