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

public struct RuntimeCapabilities: Sendable, Equatable {
    public let supportsCreate: Bool
    public let supportsDelete: Bool
    public let supportsStartStop: Bool
    public let supportsArchive: Bool
    public let supportsList: Bool
    public let supportsCompose: Bool
    public let supportsPortForwarding: Bool

    public init(
        supportsCreate: Bool = false,
        supportsDelete: Bool = false,
        supportsStartStop: Bool = false,
        supportsArchive: Bool = false,
        supportsList: Bool = false,
        supportsCompose: Bool = false,
        supportsPortForwarding: Bool = false
    ) {
        self.supportsCreate = supportsCreate
        self.supportsDelete = supportsDelete
        self.supportsStartStop = supportsStartStop
        self.supportsArchive = supportsArchive
        self.supportsList = supportsList
        self.supportsCompose = supportsCompose
        self.supportsPortForwarding = supportsPortForwarding
    }
}

public enum RemoteBackendCapabilityError: LocalizedError, Sendable {
    case unsupportedOperation(backendIdentifier: String, operation: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let backendIdentifier, let operation):
            return "Remote backend '\(backendIdentifier)' does not support \(operation)."
        }
    }
}

public protocol RemoteBackendProtocol: Sendable {
    var identifier: String { get }
    var runtimeCapabilities: RuntimeCapabilities { get }

    func openSession(sandboxId: String, workspaceStatus: WorkspaceStatus) async throws -> RemoteSandboxInfo
    func resolveCommand(sandboxId: String) async throws -> RemoteSandboxInfo
    func healthCheck() async -> Bool
}

extension RemoteBackendProtocol {
    public func openSession(
        sandboxId: String,
        workspaceStatus: WorkspaceStatus
    ) async throws -> RemoteSandboxInfo {
        switch workspaceStatus {
        case .active:
            return try await resolveCommand(sandboxId: sandboxId)
        case .stopped, .archived:
            guard runtimeCapabilities.supportsStartStop,
                let backend = self as? any StartStopCapable
            else {
                throw RemoteBackendCapabilityError.unsupportedOperation(
                    backendIdentifier: identifier,
                    operation: "starting and resuming remote workspaces"
                )
            }

            return try await backend.startSandbox(sandboxId: sandboxId)
        }
    }
}

public protocol StartStopCapable: RemoteBackendProtocol {
    func stopSandbox(sandboxId: String) async throws
    func startSandbox(sandboxId: String) async throws -> RemoteSandboxInfo
}

public protocol Archivable: RemoteBackendProtocol {
    func archiveSandbox(sandboxId: String) async throws
}

public protocol Listable: RemoteBackendProtocol {
    func listSandboxes() async throws -> [RemoteSandboxStatus]
}

public protocol ProvisionCapable: RemoteBackendProtocol {
    func createSandbox(name: String, cloneURL: String?) async throws -> RemoteSandboxInfo
    func deleteSandbox(sandboxId: String) async throws
}
