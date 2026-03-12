//
//  WorkspaceProviders.swift
//  WorkspaceManagerCore
//
//  Provider abstraction for local, cloud, and VM-backed workspaces.
//

import Foundation

public struct TerminalLaunchSpec: Sendable, Equatable {
    public let sessionKey: HostTerminalSessionKey
    public let workingDirectory: URL
    public let customCommand: String?
    public let statusAfterLaunch: WorkspaceStatus

    public init(
        sessionKey: HostTerminalSessionKey,
        workingDirectory: URL,
        customCommand: String? = nil,
        statusAfterLaunch: WorkspaceStatus = .active
    ) {
        self.sessionKey = sessionKey
        self.workingDirectory = workingDirectory
        self.customCommand = customCommand
        self.statusAfterLaunch = statusAfterLaunch
    }
}

public struct DesktopLaunchSpec: Sendable, Equatable {
    public let vncURL: URL
    public let statusAfterLaunch: WorkspaceStatus

    public init(vncURL: URL, statusAfterLaunch: WorkspaceStatus = .active) {
        self.vncURL = vncURL
        self.statusAfterLaunch = statusAfterLaunch
    }
}

public struct WorkspaceProviderAvailability: Sendable, Equatable {
    public let isAvailable: Bool
    public let reason: String?

    public init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = reason
    }

    public static let available = WorkspaceProviderAvailability(isAvailable: true)

    public static func unavailable(_ reason: String) -> WorkspaceProviderAvailability {
        WorkspaceProviderAvailability(isAvailable: false, reason: reason)
    }
}

public enum WorkspaceGuestOS: String, CaseIterable, Codable, Sendable, Identifiable {
    case linux
    case macOS = "macos"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .linux:
            return "Linux"
        case .macOS:
            return "macOS"
        }
    }
}

public struct WorkspaceProviderDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    public let supportedGuestOS: [WorkspaceGuestOS]
    public let supportsDesktop: Bool
    public let supportsArchive: Bool
    public let requiresRemoteRepository: Bool
    public let usesHostWorkspaceFiles: Bool

    public init(
        id: String,
        displayName: String,
        description: String,
        supportedGuestOS: [WorkspaceGuestOS] = [],
        supportsDesktop: Bool = false,
        supportsArchive: Bool = false,
        requiresRemoteRepository: Bool = false,
        usesHostWorkspaceFiles: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.supportedGuestOS = supportedGuestOS
        self.supportsDesktop = supportsDesktop
        self.supportsArchive = supportsArchive
        self.requiresRemoteRepository = requiresRemoteRepository
        self.usesHostWorkspaceFiles = usesHostWorkspaceFiles
    }
}

public struct WorkspaceProviderCreationRequest: Sendable {
    public let repoName: String
    public let repoLocalURL: URL
    public let repoRemoteURL: String?
    public let workspaceName: String
    public let guestOS: WorkspaceGuestOS?

    public init(
        repoName: String,
        repoLocalURL: URL,
        repoRemoteURL: String?,
        workspaceName: String,
        guestOS: WorkspaceGuestOS? = nil
    ) {
        self.repoName = repoName
        self.repoLocalURL = repoLocalURL
        self.repoRemoteURL = repoRemoteURL
        self.workspaceName = workspaceName
        self.guestOS = guestOS
    }
}

public struct WorkspaceProviderCreationResult: Sendable {
    public let name: String
    public let path: URL
    public let gitBranch: String?
    public let status: WorkspaceStatus
    public let backendIdentifier: String
    public let remoteId: String?
    public let backendMetadataRaw: String

    public init(
        name: String,
        path: URL,
        gitBranch: String? = nil,
        status: WorkspaceStatus = .active,
        backendIdentifier: String,
        remoteId: String? = nil,
        backendMetadataRaw: String = ""
    ) {
        self.name = name
        self.path = path
        self.gitBranch = gitBranch
        self.status = status
        self.backendIdentifier = backendIdentifier
        self.remoteId = remoteId
        self.backendMetadataRaw = backendMetadataRaw
    }
}

public struct WorkspaceProviderStatusSnapshot: Sendable, Equatable {
    public let remoteId: String
    public let status: WorkspaceStatus

    public init(remoteId: String, status: WorkspaceStatus) {
        self.remoteId = remoteId
        self.status = status
    }
}

public struct WorkspaceProviderTarget: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let gitBranch: String?
    public let status: WorkspaceStatus
    public let backendIdentifier: String
    public let remoteId: String?
    public let backendMetadataRaw: String

    public init(
        id: UUID,
        name: String,
        path: String,
        gitBranch: String?,
        status: WorkspaceStatus,
        backendIdentifier: String,
        remoteId: String?,
        backendMetadataRaw: String
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitBranch = gitBranch
        self.status = status
        self.backendIdentifier = backendIdentifier
        self.remoteId = remoteId
        self.backendMetadataRaw = backendMetadataRaw
    }

    public init(_ workspace: Workspace) {
        self.init(
            id: workspace.id,
            name: workspace.name,
            path: workspace.path,
            gitBranch: workspace.gitBranch,
            status: workspace.status,
            backendIdentifier: workspace.backendIdentifier,
            remoteId: workspace.remoteId,
            backendMetadataRaw: workspace.backendMetadataRaw
        )
    }

    public var workspaceURL: URL {
        URL(fileURLWithPath: path)
    }

    public func decodeBackendMetadata<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = backendMetadataRaw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

public typealias WorkspaceProviderProgressHandler = @MainActor @Sendable (String) async -> Void
public typealias WorkspaceProviderPersistenceHandler =
    @MainActor @Sendable (
        WorkspaceProviderCreationResult
    ) async throws -> Void

@preconcurrency public protocol WorkspaceProviderProtocol: Sendable {
    var descriptor: WorkspaceProviderDescriptor { get }

    func availability() async -> WorkspaceProviderAvailability
    func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey
    func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult
    func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec
    func desktopLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> DesktopLaunchSpec
    func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws
    func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws
    func archiveWorkspace(_ workspace: WorkspaceProviderTarget) async throws
    func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws
    func syncStatuses(for workspaces: [WorkspaceProviderTarget]) async throws -> [WorkspaceProviderStatusSnapshot]
}

extension WorkspaceProviderProtocol {
    public func desktopLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> DesktopLaunchSpec {
        throw WorkspaceProviderError.unsupportedOperation(
            "Desktop access is not supported by \(descriptor.displayName)"
        )
    }

    public func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        throw WorkspaceProviderError.unsupportedOperation(
            "Start is not supported by \(descriptor.displayName)"
        )
    }

    public func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        throw WorkspaceProviderError.unsupportedOperation(
            "Stop is not supported by \(descriptor.displayName)"
        )
    }

    public func archiveWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        throw WorkspaceProviderError.unsupportedOperation(
            "Archive is not supported by \(descriptor.displayName)"
        )
    }

    public func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        // Local workspaces do not require remote cleanup.
    }

    public func syncStatuses(
        for workspaces: [WorkspaceProviderTarget]
    ) async throws -> [WorkspaceProviderStatusSnapshot] {
        []
    }
}

public struct WorkspaceProviderRegistry: Sendable {
    private let providersByID: [String: any WorkspaceProviderProtocol]
    private let orderedProviderIDs: [String]

    public init(providers: [any WorkspaceProviderProtocol]) {
        var providersByID: [String: any WorkspaceProviderProtocol] = [:]
        var orderedProviderIDs: [String] = []

        for provider in providers {
            providersByID[provider.descriptor.id] = provider
            orderedProviderIDs.append(provider.descriptor.id)
        }

        self.providersByID = providersByID
        self.orderedProviderIDs = orderedProviderIDs
    }

    public var providers: [any WorkspaceProviderProtocol] {
        orderedProviderIDs.compactMap { providersByID[$0] }
    }

    public func provider(for identifier: String) -> (any WorkspaceProviderProtocol)? {
        providersByID[identifier]
    }

    public func provider(for workspace: Workspace) -> (any WorkspaceProviderProtocol)? {
        provider(for: workspace.backendIdentifier)
    }
}

extension WorkspaceProviderRegistry {
    public static let live = WorkspaceProviderRegistry(
        providers: [
            LocalWorkspaceProvider(),
            DaytonaWorkspaceProvider(),
            LumeWorkspaceProvider(),
        ]
    )
}

public enum WorkspaceProviderError: LocalizedError {
    case providerNotFound(String)
    case unsupportedOperation(String)
    case invalidWorkspace(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .providerNotFound(let identifier):
            return "Workspace provider '\(identifier)' was not found"
        case .unsupportedOperation(let message):
            return message
        case .invalidWorkspace(let message):
            return message
        case .unavailable(let message):
            return message
        }
    }
}
