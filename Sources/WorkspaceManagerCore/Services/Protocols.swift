//
//  Protocols.swift
//  WorkspaceManager
//
//  Service protocols for dependency injection and testability
//

import Foundation

// MARK: - Value types for crossing isolation boundaries

/// Sendable data needed to create a Workspace model after actor-isolated work completes.
public struct NewWorkspaceInfo: Sendable {
    public let name: String
    public let path: URL
    public let gitBranch: String

    public init(name: String, path: URL, gitBranch: String) {
        self.name = name
        self.path = path
        self.gitBranch = gitBranch
    }
}

public protocol GitServiceProtocol: Sendable {
    func getStatus(at path: URL) async throws -> [FileChange]
    func getRemoteURL(at path: URL) async throws -> String?
    func getCurrentBranch(at path: URL) async throws -> String?
    func createBranch(_ name: String, at path: URL) async throws
    func checkoutBranch(_ name: String, at path: URL) async throws
    func getFileTree(at path: URL, maxDepth: Int) async throws -> FileNode
}

extension GitServiceProtocol {
    public func getFileTree(at path: URL) async throws -> FileNode {
        try await getFileTree(at: path, maxDepth: 4)
    }
}

public protocol WorkspaceServiceProtocol: Sendable {
    var workspacesRoot: URL { get async }
    func createWorkspace(repoName: String, repoLocalURL: URL, name: String) async throws -> NewWorkspaceInfo
    func archiveWorkspace(at workspaceURL: URL) async throws
    func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws
    func runLifecycleScript(_ scriptName: String, in directory: URL) async throws -> WorkspaceService.ScriptResult
    func getWorkspaceSize(at workspaceURL: URL) async throws -> Int64
    func sanitizeFilename(_ name: String) async -> String
}

public protocol DaytonaBackendProtocol: Sendable {
    func createSandbox(name: String, cloneURL: String?) async throws -> DaytonaSandboxInfo
    func getSSHCommand(sandboxId: String) async throws -> DaytonaSandboxInfo
    func stopSandbox(sandboxId: String) async throws
    func startSandbox(sandboxId: String) async throws -> DaytonaSandboxInfo
    func archiveSandbox(sandboxId: String) async throws
    func deleteSandbox(sandboxId: String) async throws
    func listSandboxes() async throws -> [DaytonaSandboxStatus]
}
