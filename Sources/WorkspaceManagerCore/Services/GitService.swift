//
//  GitService.swift
//  WorkspaceManager
//
//  Git operations: status, file tree, branch management
//

import Foundation

public actor GitService: GitServiceProtocol {
    public static let shared = GitService()

    private init() {}

    // MARK: - Git Status

    public func getStatus(at path: URL) async throws -> [FileChange] {
        let output = try await runGit(["status", "--porcelain=v1", "-z"], at: path)
        let records =
            output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)

        var changes: [FileChange] = []
        changes.reserveCapacity(records.count)

        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }

            let statusCode = String(record.prefix(2))
            let filePath = String(record.dropFirst(3))
            guard !filePath.isEmpty else {
                index += 1
                continue
            }

            let status = mapStatus(from: statusCode)
            changes.append(FileChange(path: filePath, status: status))

            if statusCode.contains("R") || statusCode.contains("C") {
                index += 1  // Skip source path record for rename/copy entries.
            }

            index += 1
        }

        return changes
    }

    // MARK: - Remote URL

    public func getRemoteURL(at path: URL) async throws -> String? {
        let output = try await runGit(["remote", "get-url", "origin"], at: path)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Branch Operations

    public func getCurrentBranch(at path: URL) async throws -> String? {
        let output = try await runGit(["branch", "--show-current"], at: path)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func createBranch(_ name: String, at path: URL) async throws {
        _ = try await runGit(["checkout", "-b", name], at: path)
    }

    public func checkoutBranch(_ name: String, at path: URL) async throws {
        _ = try await runGit(["checkout", name], at: path)
    }

    /// List local and `origin/*` remote branches. Sorted locals-first, current at top.
    public func branches(at path: URL) async throws -> [BranchName] {
        let current = try await getCurrentBranch(at: path) ?? ""

        let output = try await runGit(
            [
                "for-each-ref",
                "--format=%(refname)",
                "refs/heads",
                "refs/remotes/origin",
            ],
            at: path
        )

        var locals: [BranchName] = []
        var remotes: [BranchName] = []

        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let ref = String(raw)
            if let name = ref.dropPrefix("refs/heads/") {
                locals.append(BranchName(name: name, isCurrent: name == current, isRemote: false))
            } else if let name = ref.dropPrefix("refs/remotes/origin/") {
                if name == "HEAD" { continue }
                remotes.append(BranchName(name: name, isCurrent: false, isRemote: true))
            }
        }

        locals.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        remotes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return locals + remotes
    }

    // MARK: - Diff / Stage / Unstage / Discard

    /// Structured working-tree-vs-index diff for a single file.
    public func diff(file: String, at path: URL) async throws -> UnifiedDiff {
        let output = try await runGit(["diff", "--no-color", "--", file], at: path)
        return try UnifiedDiff.parse(output, path: file)
    }

    public func stage(file: String, at path: URL) async throws {
        _ = try await runGit(["add", "--", file], at: path)
    }

    public func unstage(file: String, at path: URL) async throws {
        _ = try await runGit(["reset", "HEAD", "--", file], at: path)
    }

    /// Discard working-tree changes for `file`, restoring HEAD contents.
    /// Destructive: unstaged edits are lost without recovery.
    public func discard(file: String, at path: URL) async throws {
        _ = try await runGit(["checkout", "--", file], at: path)
    }

    // MARK: - File Tree

    public func getFileTree(at path: URL, maxDepth: Int = 4) async throws -> FileNode {
        try await buildTree(at: path, relativePath: "", depth: 0, maxDepth: maxDepth)
    }

    private func buildTree(
        at baseURL: URL,
        relativePath: String,
        depth: Int,
        maxDepth: Int
    ) async throws -> FileNode {
        let currentURL =
            relativePath.isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(relativePath)

        let name =
            relativePath.isEmpty
            ? baseURL.lastPathComponent
            : (relativePath as NSString).lastPathComponent

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDirectory) else {
            return FileNode(name: name, path: relativePath, isDirectory: false, children: nil)
        }

        if !isDirectory.boolValue {
            return FileNode(name: name, path: relativePath, isDirectory: false, children: nil)
        }

        guard depth < maxDepth else {
            return FileNode(name: name, path: relativePath, isDirectory: true, children: nil)
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: currentURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )

        let ignoredDirs = Set([
            "node_modules", ".git", ".build", "build", "DerivedData", ".swiftpm", "__pycache__", ".venv", "venv",
        ])

        let children = try await withThrowingTaskGroup(of: FileNode?.self) { group in
            for itemURL in contents {
                let itemName = itemURL.lastPathComponent

                if ignoredDirs.contains(itemName) {
                    continue
                }

                group.addTask {
                    let childPath =
                        relativePath.isEmpty
                        ? itemName
                        : (relativePath as NSString).appendingPathComponent(itemName)

                    return try await self.buildTree(
                        at: baseURL,
                        relativePath: childPath,
                        depth: depth + 1,
                        maxDepth: maxDepth
                    )
                }
            }

            var results: [FileNode] = []
            for try await child in group {
                if let child {
                    results.append(child)
                }
            }
            return results
        }

        let sortedChildren = children.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return FileNode(
            name: name,
            path: relativePath,
            isDirectory: true,
            children: sortedChildren
        )
    }

    // MARK: - Run Git Command

    private func runGit(_ args: [String], at path: URL) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: args,
            currentDirectory: path
        )

        if result.exitCode != 0 {
            let stderr = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw GitError.commandFailed(args: args, stderr: stderr)
        }

        return result.stdout
    }

    private func mapStatus(from porcelainCode: String) -> GitStatus {
        if porcelainCode == "??" {
            return .untracked
        }
        if porcelainCode == "A " {
            return .added
        }
        if porcelainCode.contains("R") || porcelainCode.contains("C") {
            return .renamed
        }
        if porcelainCode.contains("D") {
            return .deleted
        }
        if porcelainCode.contains("M") || porcelainCode.contains("A") {
            return .modified
        }
        return .modified
    }
}

// MARK: - Value Types

public struct BranchName: Hashable, Sendable {
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool

    public init(name: String, isCurrent: Bool, isRemote: Bool) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
    }
}

extension String {
    fileprivate func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

// MARK: - Errors

public enum GitError: LocalizedError {
    case commandFailed(args: [String], stderr: String)
    case notARepository

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let args, let stderr):
            return "Git command failed: git \(args.joined(separator: " "))\n\(stderr)"
        case .notARepository:
            return "Not a git repository"
        }
    }
}
