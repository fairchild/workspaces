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

public enum WorkspaceCreationPhase: String, CaseIterable, Sendable {
    case preparing
    case copyingRepository
    case creatingBranch
    case runningSetupScript
    case finished
}

public typealias WorkspaceCreationProgressHandler = @Sendable (WorkspaceCreationPhase) async -> Void

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
    func createWorkspace(
        repoName: String,
        repoLocalURL: URL,
        name: String,
        progress: WorkspaceCreationProgressHandler?
    ) async throws -> NewWorkspaceInfo
    func archiveWorkspace(at workspaceURL: URL) async throws
    func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws
    func runLifecycleScript(_ scriptName: String, in directory: URL) async throws -> WorkspaceService.ScriptResult
    func getWorkspaceSize(at workspaceURL: URL) async throws -> Int64
    func sanitizeFilename(_ name: String) async -> String
}

extension WorkspaceServiceProtocol {
    public func createWorkspace(
        repoName: String,
        repoLocalURL: URL,
        name: String
    ) async throws -> NewWorkspaceInfo {
        try await createWorkspace(
            repoName: repoName,
            repoLocalURL: repoLocalURL,
            name: name,
            progress: nil
        )
    }
}

public protocol WorkspaceProcessMonitorProtocol: Sendable {
    func detectAgents(in workspaceDirectories: [UUID: URL]) async -> [UUID: WorkspaceProcessMonitor.AgentStatus]
    func detectAgentSession(in workspaceDirectory: URL) async -> WorkspaceProcessMonitor.AgentStatus
}

public enum StreamDisconnectReason: Sendable, Equatable {
    case none
    case transportError
    case authFailure
}

public protocol EventStreamServiceProtocol: Sendable {
    func connect(owner: String, jwt: String, githubToken: String?) async
    func disconnect() async
    var events: AsyncStream<WebhookEvent> { get async }
    var isConnected: Bool { get async }
    var lastDisconnectReason: StreamDisconnectReason { get async }
}

public protocol GitHubDeviceAuthProtocol: Sendable {
    func requestDeviceCode(scope: String) async throws -> DeviceCodeResponse
    func pollForToken(deviceCode: String, interval: Int) async throws -> GitHubAuthToken
}

extension GitHubDeviceAuthProtocol {
    public func requestDeviceCode() async throws -> DeviceCodeResponse {
        try await requestDeviceCode(scope: "")
    }
}

public protocol NotificationSessionServiceProtocol: Sendable {
    func createSession(githubToken: String) async throws -> NotificationSession
}

// MARK: - Notification coordinator

public enum NotificationAuthState: Sendable, Equatable {
    case signedOut
    case requestingCode
    case awaitingUserAuth(userCode: String, verificationURL: String)
    case exchangingToken
    case signedIn(login: String)
    case failed(String)
}

@MainActor
public protocol NotificationCoordinatorProtocol: AnyObject {
    var authState: NotificationAuthState { get }
    var isStreamConnected: Bool { get }
    var events: [WebhookEvent] { get }
    var unseenEventCount: Int { get }

    func startDeviceFlow() async
    func signOut()
    func loadStoredAuth()
    func connectStream(remoteURL: String) async
    func disconnectStream() async
    func markActivitySeen()
}

public protocol RemoteBackendProtocol: Sendable {
    var identifier: String { get }
    func isAvailable() async -> Bool

    func createSandbox(name: String, cloneURL: String?) async throws -> RemoteSandboxInfo
    func getSSHCommand(sandboxId: String) async throws -> RemoteSandboxInfo
    func stopSandbox(sandboxId: String) async throws
    func startSandbox(sandboxId: String) async throws -> RemoteSandboxInfo
    func archiveSandbox(sandboxId: String) async throws
    func deleteSandbox(sandboxId: String) async throws
    func listSandboxes() async throws -> [RemoteSandboxStatus]
}
