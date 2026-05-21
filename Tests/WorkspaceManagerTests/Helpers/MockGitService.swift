//
//  MockGitService.swift
//  WorkspaceManagerTests
//
//  Configurable mock for GitServiceProtocol with call tracking
//

import Foundation

@testable import WorkspaceManagerCore

final class MockGitService: GitServiceProtocol, @unchecked Sendable {

    // MARK: - Call Tracking

    var createBranchCalls: [(name: String, path: URL)] = []
    var getCurrentBranchCalls: [URL] = []

    // MARK: - Configurable Returns

    var statusResult: [FileChange] = []
    var remoteURLResult: String? = nil
    var currentBranchResult: String? = "main"
    var fileTreeResult: FileNode = FileNode(name: "root", path: "", isDirectory: true, children: [])
    var createBranchError: Error? = nil

    // MARK: - Protocol Conformance

    func getStatus(at path: URL) async throws -> [FileChange] {
        statusResult
    }

    func getRemoteURL(at path: URL) async throws -> String? {
        remoteURLResult
    }

    func getCurrentBranch(at path: URL) async throws -> String? {
        getCurrentBranchCalls.append(path)
        return currentBranchResult
    }

    func createBranch(_ name: String, at path: URL) async throws {
        createBranchCalls.append((name: name, path: path))
        if let error = createBranchError {
            throw error
        }
    }

    func checkoutBranch(_ name: String, at path: URL) async throws {}

    func getFileTree(at path: URL, maxDepth: Int) async throws -> FileNode {
        fileTreeResult
    }

    // MARK: - Diff / Stage / Unstage / Discard (M5 prep)

    var diffResult: UnifiedDiff = UnifiedDiff(path: "", hunks: [])
    var stageCalls: [(file: String, path: URL)] = []
    var unstageCalls: [(file: String, path: URL)] = []
    var discardCalls: [(file: String, path: URL)] = []

    func diff(file: String, at path: URL) async throws -> UnifiedDiff {
        diffResult
    }

    func stage(file: String, at path: URL) async throws {
        stageCalls.append((file: file, path: path))
    }

    func unstage(file: String, at path: URL) async throws {
        unstageCalls.append((file: file, path: path))
    }

    func discard(file: String, at path: URL) async throws {
        discardCalls.append((file: file, path: path))
    }

    // MARK: - Branches (M8 prep)

    var branchesResult: [BranchName] = []

    func branches(at path: URL) async throws -> [BranchName] {
        branchesResult
    }
}
