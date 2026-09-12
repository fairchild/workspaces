// Routes inspection and review actions for Compose workspaces into their agent
// container. A stopped or unavailable container is an error; repository metadata
// writable by an agent must never cause Git to execute on the host.

import Foundation
import WorkspaceManagerCore

struct ComposeRepositoryInspection: Sendable {
    typealias GitExecutor = @Sendable ([String], WorkspaceProviderTarget) async throws -> String

    let workspace: WorkspaceProviderTarget?
    let directoryURL: URL
    let hostGit: any GitServiceProtocol
    private let executeGit: GitExecutor

    init(
        workspace: WorkspaceProviderTarget?,
        directoryURL: URL,
        hostGit: any GitServiceProtocol,
        executeGit: @escaping GitExecutor = { arguments, workspace in
            try await ComposeWorkspaceProvider.shared.executeGit(arguments: arguments, for: workspace)
        }
    ) {
        self.workspace = workspace
        self.directoryURL = directoryURL
        self.hostGit = hostGit
        self.executeGit = executeGit
    }

    func fileTree() async throws -> FileNode {
        if workspace != nil {
            return try await Task.detached(priority: .userInitiated) {
                try ComposeSafeFiles.fileTree(at: directoryURL)
            }.value
        }
        return try await hostGit.getFileTree(at: directoryURL)
    }

    func status() async throws -> [FileChange] {
        guard let workspace else { return try await hostGit.getStatus(at: directoryURL) }
        return Self.parseStatus(
            try await executeGit(["status", "--porcelain=v1", "--untracked-files=all", "-z"], workspace))
    }

    func diff(file: String) async throws -> UnifiedDiff {
        guard let workspace else { return try await hostGit.diff(file: file, at: directoryURL) }
        try ComposeSafeFiles.validate(relativePath: file)
        let output = try await executeGit(
            ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--", file], workspace)
        return try UnifiedDiff.parse(output, path: file)
    }

    func stage(file: String) async throws {
        guard let workspace else { return try await hostGit.stage(file: file, at: directoryURL) }
        try ComposeSafeFiles.validate(relativePath: file)
        _ = try await executeGit(["--literal-pathspecs", "add", "--", file], workspace)
    }

    func unstage(file: String) async throws {
        guard let workspace else { return try await hostGit.unstage(file: file, at: directoryURL) }
        try ComposeSafeFiles.validate(relativePath: file)
        _ = try await executeGit(["--literal-pathspecs", "reset", "HEAD", "--", file], workspace)
    }

    func discard(file: String, untracked: Bool) async throws {
        guard let workspace else {
            if untracked {
                try await hostGit.discardUntracked(file: file, at: directoryURL)
            } else {
                try await hostGit.discard(file: file, at: directoryURL)
            }
            return
        }
        try ComposeSafeFiles.validate(relativePath: file)
        // `clean` is restricted to this literal file, never a host-side unlink.
        let arguments =
            untracked
            ? ["--literal-pathspecs", "clean", "-f", "--", file]
            : ["--literal-pathspecs", "checkout", "--", file]
        _ = try await executeGit(arguments, workspace)
    }

    static func parseStatus(_ output: String) -> [FileChange] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [FileChange] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= 4 else { continue }
            let code = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            let status: GitStatus
            if code == "??" {
                status = .untracked
            } else if code == "A " {
                status = .added
            } else if code.contains("R") || code.contains("C") {
                status = .renamed
            } else if code.contains("D") {
                status = .deleted
            } else {
                status = .modified
            }
            changes.append(FileChange(path: path, status: status))
            if code.contains("R") || code.contains("C") { index += 1 }
        }
        return changes
    }
}
