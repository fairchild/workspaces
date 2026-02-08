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
        let output = try await runGit(["status", "--porcelain=v1"], at: path)

        return
            output
            .split(separator: "\n")
            .compactMap { line -> FileChange? in
                let line = String(line)
                guard line.count >= 3 else { return nil }

                let statusCode = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
                let filePath = String(line.dropFirst(3))

                let status: GitStatus
                switch statusCode {
                case "M", "MM", "AM": status = .modified
                case "A": status = .added
                case "D": status = .deleted
                case "??": status = .untracked
                case "R", "RM": status = .renamed
                default: status = .modified
                }

                return FileChange(path: filePath, status: status)
            }
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
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = path

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: GitError.commandFailed(args: args, stderr: stderr))
                } else {
                    continuation.resume(returning: String(data: stdoutData, encoding: .utf8) ?? "")
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
