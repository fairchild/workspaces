//
//  WorkspaceMaterializer.swift
//  WorkspaceManager
//
//  Materializes local workspace directories behind a small strategy interface.
//

import Foundation

struct MaterializedWorkspace: Sendable {
    let gitBranch: String
}

protocol WorkspaceMaterializer: Sendable {
    var failureOperationDescription: String { get }

    /// Creates a local workspace at `destination` from `sourceRepository`.
    /// Implementations own their repository mechanics; callers own destination validation and lifecycle hooks.
    func materializeWorkspace(
        named sanitizedName: String,
        at destination: URL,
        from sourceRepository: URL,
        fromRef: String?
    ) async throws -> MaterializedWorkspace

    func removeWorkspace(at workspaceURL: URL) async throws
}

extension WorkspaceMaterializer {
    func removeWorkspace(at workspaceURL: URL) async throws {
        try await WorkspaceDirectoryRemover.remove(at: workspaceURL)
    }
}

struct GitWorktreeWorkspaceMaterializer: WorkspaceMaterializer {
    let gitService: any GitServiceProtocol

    var failureOperationDescription: String {
        "create git worktree"
    }

    init(gitService: any GitServiceProtocol = GitService.shared) {
        self.gitService = gitService
    }

    func materializeWorkspace(
        named sanitizedName: String,
        at destination: URL,
        from sourceRepository: URL,
        fromRef: String? = nil
    ) async throws -> MaterializedWorkspace {
        let branchName = "workspace/\(sanitizedName)"
        if fromRef != nil {
            try await gitService.fetchAll(at: sourceRepository)
        }
        try await gitService.createWorktree(
            branchName: branchName,
            at: destination,
            from: sourceRepository,
            startPoint: fromRef
        )

        let currentBranch = try? await gitService.getCurrentBranch(at: destination)
        return MaterializedWorkspace(gitBranch: currentBranch ?? branchName)
    }
}

struct GitCloneWorkspaceMaterializer: WorkspaceMaterializer {
    let gitService: any GitServiceProtocol

    var failureOperationDescription: String {
        "copy repository"
    }

    init(gitService: any GitServiceProtocol = GitService.shared) {
        self.gitService = gitService
    }

    func materializeWorkspace(
        named sanitizedName: String,
        at destination: URL,
        from sourceRepository: URL,
        fromRef: String? = nil
    ) async throws -> MaterializedWorkspace {
        if fromRef != nil {
            try await gitService.fetchAll(at: sourceRepository)
        }

        let cloneArguments = [
            "clone",
            "--local",
            "--no-hardlinks",
            sourceRepository.path,
            destination.path,
        ]
        let cloneResult = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: cloneArguments,
            currentDirectory: sourceRepository.deletingLastPathComponent(),
            timeout: 30
        )
        guard cloneResult.success else {
            let reason = cloneResult.stderr.isEmpty ? "Unknown error" : cloneResult.stderr
            throw GitError.commandFailed(args: cloneArguments, stderr: reason)
        }

        let branchName = "workspace/\(sanitizedName)"
        try await gitService.createBranch(branchName, at: destination)
        if let fromRef {
            let checkoutArguments = ["reset", "--hard", fromRef]
            let checkoutResult = try await ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: checkoutArguments,
                currentDirectory: destination,
                timeout: 30
            )
            guard checkoutResult.success else {
                let reason = checkoutResult.stderr.isEmpty ? "Unknown error" : checkoutResult.stderr
                throw GitError.commandFailed(args: checkoutArguments, stderr: reason)
            }
        }
        let currentBranch = try? await gitService.getCurrentBranch(at: destination)

        return MaterializedWorkspace(gitBranch: currentBranch ?? branchName)
    }
}
