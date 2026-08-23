//
//  GitService.swift
//  WorkspaceManager
//
//  Git operations: status, file tree, branch management
//

import Darwin
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

    public func fetchAll(at path: URL) async throws {
        _ = try await runGit(["fetch", "--all", "--prune"], at: path)
    }

    public func createBranch(_ name: String, at path: URL) async throws {
        _ = try await runGit(["checkout", "-b", name], at: path)
    }

    public func createWorktree(
        branchName: String,
        at destination: URL,
        from source: URL,
        startPoint: String? = nil
    ) async throws {
        if try await localBranchExists(branchName, at: source) {
            throw GitError.branchAlreadyExists(name: branchName)
        }

        let args = ["worktree", "add", "-b", branchName, destination.path, startPoint ?? "HEAD"]
        let result = try await runGitResult(args, at: source)
        guard result.success else {
            try? await deleteLocalBranchIfExists(branchName, at: source)
            let stderr = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw GitError.commandFailed(args: args, stderr: stderr)
        }
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

    /// Discard working-tree changes for a tracked `file`, restoring its index/HEAD contents.
    /// Destructive: unstaged edits are lost without recovery. Untracked files are inert here
    /// (`git checkout --` ignores them) — use `discardUntracked` for those so a "discard" of a
    /// new file is never a silent no-op.
    public func discard(file: String, at path: URL) async throws {
        _ = try await runGit(["checkout", "--", file], at: path)
    }

    /// Remove a single untracked `file`. Destructive and unrecoverable: untracked files are not
    /// in git history, so this is the only "discard" path that deletes real content. Kept as
    /// narrow as possible — it deletes exactly the one resolved path via the filesystem (never
    /// `git clean`, which could sweep siblings), and only after confirming the path stays inside
    /// `path` and is a regular file rather than a symlink. Callers must confirm-gate it in the UI.
    public func discardUntracked(file: String, at path: URL) async throws {
        let lexicalTarget = try Self.lexicalFileURL(rootURL: path, relativePath: file)

        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: lexicalTarget.path)) == nil
        else {
            throw GitError.symlinkRefused
        }

        // Containment is checked on the symlink-resolved path so an intermediate symlink cannot
        // escape the root; deletion targets the lexical path git reported.
        _ = try Self.containedFileURL(rootURL: path, relativePath: file)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lexicalTarget.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw GitError.untrackedTargetMissing(relativePath: file)
        }

        // Defense in depth against a stale caller status: confirm git does not track this path
        // before deleting it. `ls-files --error-unmatch` exits 0 only for a tracked path; a tracked
        // file must go through `discard` (recoverable) rather than an unrecoverable delete.
        let tracked = try await runGitResult(["ls-files", "--error-unmatch", "--", file], at: path)
        guard tracked.exitCode != 0 else {
            throw GitError.discardUntrackedOnTrackedFile(relativePath: file)
        }

        // The lexical checks above race a concurrent swap of an intermediate directory to a
        // symlink (TOCTOU). Delete via an O_NOFOLLOW descriptor walk so the unlink cannot follow a
        // symlink that appeared after the containment check and escape the root.
        try Self.raceSafeUnlink(root: path, relativePath: file)
    }

    /// Unlink `relativePath` under `rootURL` without following a symlink in any path component:
    /// walks the directories with `O_NOFOLLOW` and unlinks relative to the parent descriptor. A
    /// concurrent swap of an intermediate directory to a symlink fails the walk instead of
    /// escaping the root, and the leaf must still be a regular file at unlink time.
    static func raceSafeUnlink(root: URL, relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(
            String.init)
        guard let leaf = components.last,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw GitError.invalidRelativePath(relativePath)
        }

        var directoryFD = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY) }
        guard directoryFD >= 0 else {
            throw GitError.untrackedTargetMissing(relativePath: relativePath)
        }
        var openFDs = [directoryFD]
        defer {
            for fd in openFDs { close(fd) }
        }

        for component in components.dropLast() {
            let childFD = component.withCString {
                openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard childFD >= 0 else {
                throw GitError.pathEscapesRoot
            }
            openFDs.append(childFD)
            directoryFD = childFD
        }

        var info = stat()
        let statResult = leaf.withCString { fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        guard statResult == 0 else {
            throw GitError.untrackedTargetMissing(relativePath: relativePath)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw GitError.symlinkRefused
        }

        guard leaf.withCString({ unlinkat(directoryFD, $0, 0) }) == 0 else {
            throw GitError.untrackedDeleteFailed(relativePath: relativePath)
        }
    }

    /// Lexical (non-symlink-resolved) URL for `relativePath` under `rootURL`, rejecting absolute
    /// paths and `.`/`..` traversal components before any filesystem touch.
    static func lexicalFileURL(rootURL: URL, relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            components.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." })
        else {
            throw GitError.invalidRelativePath(relativePath)
        }
        return rootURL.appendingPathComponent(relativePath).standardizedFileURL
    }

    /// Symlink-resolved URL for `relativePath`, throwing `pathEscapesRoot` if it lands outside
    /// the resolved `rootURL`.
    static func containedFileURL(rootURL: URL, relativePath: String) throws -> URL {
        let lexicalTarget = try lexicalFileURL(rootURL: rootURL, relativePath: relativePath)
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let target = lexicalTarget.resolvingSymlinksInPath()
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw GitError.pathEscapesRoot
        }
        return target
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
            if relativePath.isEmpty {
                throw GitError.fileTreeRootUnavailable
            }
            return FileNode(name: name, path: relativePath, isDirectory: false, children: nil)
        }

        if relativePath.isEmpty, !isDirectory.boolValue {
            throw GitError.fileTreeRootUnavailable
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
        let result = try await runGitResult(args, at: path)

        if result.exitCode != 0 {
            let stderr = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw GitError.commandFailed(args: args, stderr: stderr)
        }

        return result.stdout
    }

    private func runGitResult(_ args: [String], at path: URL) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: args,
            currentDirectory: path,
            timeout: 30
        )
    }

    private func localBranchExists(_ name: String, at path: URL) async throws -> Bool {
        let args = ["show-ref", "--verify", "--quiet", "refs/heads/\(name)"]
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: args,
            currentDirectory: path,
            timeout: 30
        )

        if result.exitCode == 0 {
            return true
        }
        if result.exitCode == 1 {
            return false
        }

        let stderr = result.stderr.isEmpty ? "Unknown error" : result.stderr
        throw GitError.commandFailed(args: args, stderr: stderr)
    }

    private func deleteLocalBranchIfExists(_ name: String, at path: URL) async throws {
        guard try await localBranchExists(name, at: path) else { return }
        let args = ["branch", "-D", name]
        let result = try await runGitResult(args, at: path)

        if result.exitCode != 0 {
            let stderr = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw GitError.commandFailed(args: args, stderr: stderr)
        }
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

public enum GitError: LocalizedError, Equatable {
    case commandFailed(args: [String], stderr: String)
    case notARepository
    case fileTreeRootUnavailable
    case branchAlreadyExists(name: String)
    case invalidRelativePath(String)
    case pathEscapesRoot
    case symlinkRefused
    case untrackedTargetMissing(relativePath: String)
    case discardUntrackedOnTrackedFile(relativePath: String)
    case untrackedDeleteFailed(relativePath: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let args, let stderr):
            return "Git command failed: git \(args.joined(separator: " "))\n\(stderr)"
        case .notARepository:
            return "Not a git repository"
        case .fileTreeRootUnavailable:
            return "The file tree root is not an available directory"
        case .branchAlreadyExists(let name):
            return "A branch named '\(name)' already exists"
        case .invalidRelativePath(let path):
            return "Refused because '\(path)' is not a valid relative file path."
        case .pathEscapesRoot:
            return "Refused because the selected path resolves outside the repository root."
        case .symlinkRefused:
            return "Refused because the selected file is a symbolic link."
        case .untrackedTargetMissing(let path):
            return "There is no untracked file at '\(path)' to delete."
        case .discardUntrackedOnTrackedFile(let path):
            return "Refused to delete '\(path)' because git tracks it; discard its changes instead."
        case .untrackedDeleteFailed(let path):
            return "Could not delete the untracked file '\(path)'."
        }
    }
}
