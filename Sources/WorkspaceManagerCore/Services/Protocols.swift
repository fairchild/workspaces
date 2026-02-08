//
//  Protocols.swift
//  WorkspaceManager
//
//  Service protocols for dependency injection and testability
//

import Foundation

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
    func createWorkspace(from repo: Repo, name: String) async throws -> Workspace
    func archiveWorkspace(_ workspace: Workspace) async throws
    func deleteWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws
    func runLifecycleScript(_ scriptName: String, in directory: URL) async throws -> WorkspaceService.ScriptResult
    func getWorkspaceSize(_ workspace: Workspace) async throws -> Int64
    func sanitizeFilename(_ name: String) async -> String
}
