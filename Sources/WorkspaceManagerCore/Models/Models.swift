//
//  Models.swift
//  WorkspaceManager
//
//  SwiftData models for persistence
//

import Foundation
import SwiftData
import SwiftUI  // For Color in GitStatus

@Model
public final class Repo {
    public var id: UUID
    public var name: String
    public var localPath: String  // Store as String, convert to URL when needed
    public var remoteURL: String?
    public var addedAt: Date
    public var lastAccessedAt: Date = Date()

    /// Repo-level default agent command (e.g. `claude --resume`). Overrides the
    /// global default; overridden by a workspace's own `defaultAgentCommand`.
    public var defaultAgentCommand: String?

    @Relationship(deleteRule: .cascade, inverse: \Workspace.sourceRepo)
    public var workspaces: [Workspace] = []

    @Relationship(deleteRule: .cascade, inverse: \WebSource.sourceRepo)
    public var webSources: [WebSource] = []

    public var localURL: URL {
        URL(fileURLWithPath: localPath)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        localPath: URL,
        remoteURL: String? = nil,
        addedAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        defaultAgentCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.localPath = localPath.path
        self.remoteURL = remoteURL
        self.addedAt = addedAt
        self.lastAccessedAt = lastAccessedAt
        self.defaultAgentCommand = defaultAgentCommand
    }
}

@Model
public final class WebSource {
    public var id: UUID
    public var name: String
    public var baseURLString: String
    public var allowedHost: String
    public var additionalAllowedDomainsRaw: String = ""
    public var addedAt: Date
    public var lastAccessedAt: Date
    public var sourceRepo: Repo?
    public var sourceWorkspace: Workspace?

    public var baseURL: URL? {
        URL(string: baseURLString)
    }

    public var ownershipScope: WebSourceOwnershipScope {
        if let sourceWorkspace {
            return .workspace(sourceWorkspace.id)
        }
        if let sourceRepo {
            return .repo(sourceRepo.id)
        }
        return .global
    }

    public var ownerRepo: Repo? {
        sourceWorkspace?.sourceRepo ?? sourceRepo
    }

    public var isGlobal: Bool {
        sourceRepo == nil && sourceWorkspace == nil
    }

    public var additionalAllowedDomains: [String] {
        get {
            Self.decodeAdditionalAllowedDomains(additionalAllowedDomainsRaw)
        }
        set {
            additionalAllowedDomainsRaw = Self.encodeAdditionalAllowedDomains(newValue)
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        baseURLString: String,
        allowedHost: String,
        additionalAllowedDomains: [String] = [],
        addedAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        sourceRepo: Repo? = nil,
        sourceWorkspace: Workspace? = nil
    ) {
        guard sourceRepo == nil || sourceWorkspace == nil else {
            fatalError("WebSource cannot be owned by both a repo and a workspace")
        }
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.allowedHost = allowedHost.lowercased()
        self.additionalAllowedDomainsRaw = Self.encodeAdditionalAllowedDomains(additionalAllowedDomains)
        self.addedAt = addedAt
        self.lastAccessedAt = lastAccessedAt
        self.sourceRepo = sourceRepo
        self.sourceWorkspace = sourceWorkspace
    }

    private static func decodeAdditionalAllowedDomains(_ rawValue: String) -> [String] {
        rawValue
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func encodeAdditionalAllowedDomains(_ domains: [String]) -> String {
        domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public struct SSHWorkspaceMetadata: Codable, Equatable, Sendable {
    public var host: String
    public var user: String?
    public var port: Int
    public var authMode: String?
    public var workingDir: String?

    public init(
        host: String,
        user: String? = nil,
        port: Int = 22,
        authMode: String? = nil,
        workingDir: String? = nil
    ) {
        self.host = host
        self.user = user
        self.port = port
        self.authMode = authMode
        self.workingDir = workingDir
    }
}

public struct KubernetesWorkspaceMetadata: Codable, Equatable, Sendable {
    public var context: String
    public var namespace: String?
    public var pod: String?
    public var deployment: String?
    public var container: String?

    public init(
        context: String,
        namespace: String? = nil,
        pod: String? = nil,
        deployment: String? = nil,
        container: String? = nil
    ) {
        self.context = context
        self.namespace = namespace
        self.pod = pod
        self.deployment = deployment
        self.container = container
    }
}

public struct ComposeWorkspaceMetadata: Codable, Equatable, Sendable {
    public var projectName: String?
    public var composeFiles: [String]
    public var service: String
    public var workdir: String?

    public init(
        projectName: String? = nil,
        composeFiles: [String] = [],
        service: String,
        workdir: String? = nil
    ) {
        self.projectName = projectName
        self.composeFiles = composeFiles
        self.service = service
        self.workdir = workdir
    }
}

private struct WorkspaceRemoteMetadataPayload: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case ssh
        case kubernetes
        case compose
    }

    enum Kind: String, Codable, Sendable {
        case ssh
        case kubernetes
        case compose
    }

    var ssh: SSHWorkspaceMetadata?
    var kubernetes: KubernetesWorkspaceMetadata?
    var compose: ComposeWorkspaceMetadata?

    init(
        ssh: SSHWorkspaceMetadata? = nil,
        kubernetes: KubernetesWorkspaceMetadata? = nil,
        compose: ComposeWorkspaceMetadata? = nil
    ) {
        self.ssh = ssh
        self.kubernetes = kubernetes
        self.compose = compose
    }

    var isEmpty: Bool {
        ssh == nil && kubernetes == nil && compose == nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ssh = try container.decodeIfPresent(SSHWorkspaceMetadata.self, forKey: .ssh)
        let kubernetes = try container.decodeIfPresent(
            KubernetesWorkspaceMetadata.self,
            forKey: .kubernetes
        )
        let compose = try container.decodeIfPresent(
            ComposeWorkspaceMetadata.self,
            forKey: .compose
        )

        if ssh != nil || kubernetes != nil || compose != nil {
            self.init(ssh: ssh, kubernetes: kubernetes, compose: compose)
            return
        }

        if container.contains(.kind) {
            let kind = try container.decode(Kind.self, forKey: .kind)
            switch kind {
            case .ssh:
                self.init(
                    ssh: ssh
                )
            case .kubernetes:
                self.init(
                    kubernetes: kubernetes
                )
            case .compose:
                self.init(
                    compose: compose
                )
            }
            return
        }

        self.init()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(ssh, forKey: .ssh)
        try container.encodeIfPresent(kubernetes, forKey: .kubernetes)
        try container.encodeIfPresent(compose, forKey: .compose)
    }
}

@Model
public final class Workspace {
    public static let remotePathSentinel = "/__workspace_manager_remote__"

    public var id: UUID
    public var name: String
    public var path: String  // Store as String, convert to URL when needed
    public var sourceRepo: Repo?
    public var createdAt: Date
    public var lastAccessedAt: Date
    public var statusRaw: String
    public var gitBranch: String?

    /// When the workspace was archived (its directory moved to `.archived/`).
    /// `nil` while active; drives the purge-after-delay sweep.
    public var archivedAt: Date?

    /// True for a workspace whose directory the app adopted rather than created — an existing
    /// git worktree matched to a `Workspace` record after the fact (#1390). Excluded from the
    /// archived-workspace purge sweep unconditionally: that sweep deletes files with
    /// `deleteFiles: true` on a timer the user does not directly act on, and a directory this
    /// app did not create may be someone's primary clone, hold uncommitted work outside git's
    /// view, or simply be a worktree another tool still expects to find. Archiving an adopted
    /// workspace is still allowed — it only ever moves the sidebar row — the purge is the one
    /// path this flag closes.
    public var isAdopted: Bool = false

    /// Position in the sidebar's Pinned section, renumbered 0…n on every pin change.
    /// `nil` for an unpinned workspace.
    public var pinOrder: Int?

    /// The workspace's **Note**: one short line about where this work stream stands,
    /// written by whoever is driving it. Distinct from `status` (a lifecycle state the
    /// app owns) and from the sidebar's transient action message — a note outlives the
    /// action that wrote it, which is what makes it worth persisting.
    /// `nil` when unset; normalize through `WorkspaceNote` before assigning.
    public var note: String?

    /// Workspace-level default agent command (e.g. `claude --resume`). Most
    /// specific tier — overrides both the repo and global defaults.
    public var defaultAgentCommand: String?

    /// Isolation backend identifier ("local", "daytona", etc.)
    public var backendIdentifier: String = "local"

    /// Remote instance ID (nil for local workspaces)
    public var remoteId: String?

    /// Stable terminal-routing identity for workspaces whose provider ID is not a lifecycle ID.
    public var sessionRoutingID: String?

    /// Provider-specific metadata (Lume VM config, Daytona sandbox info) encoded as JSON.
    /// Decoded via `decodeBackendMetadata<T>()`. Distinct from `remoteMetadataJSON` which
    /// stores connection-layer config (SSH, Docker Compose).
    public var backendMetadataRaw: String = ""

    /// Connection-layer metadata (SSH host/port, Docker Compose config) encoded as JSON.
    /// Accessed via `sshMetadata`, `composeMetadata`, `kubernetesMetadata` computed properties.
    /// Distinct from `backendMetadataRaw` which stores provider-specific workspace config.
    public var remoteMetadataJSON: String = ""

    @Relationship(deleteRule: .cascade, inverse: \WebSource.sourceWorkspace)
    public var webSources: [WebSource] = []

    public var workspaceURL: URL {
        URL(fileURLWithPath: path)
    }

    public var localDirectoryURL: URL? {
        guard usesHostWorkspaceFiles, path != Self.remotePathSentinel else { return nil }
        return workspaceURL
    }

    public var backend: BackendKind {
        get { BackendKind(rawValue: backendIdentifier) }
        set { backendIdentifier = newValue.rawValue }
    }

    public var isRemote: Bool {
        backend != .local
    }

    public var isPinned: Bool {
        pinOrder != nil
    }

    public var usesHostWorkspaceFiles: Bool {
        switch backend {
        case .local, .lume: return true
        case .daytona, .ssh, .unknown: return false
        }
    }

    public var terminalSessionIdentifier: String {
        if let sessionRoutingID = sessionRoutingID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionRoutingID.isEmpty
        {
            return sessionRoutingID
        }

        if let remoteId = remoteId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !remoteId.isEmpty
        {
            return remoteId
        }

        return id.uuidString
    }

    public var remoteSessionRequest: RemoteWorkspaceSessionRequest {
        RemoteWorkspaceSessionRequest(
            workspaceID: id,
            name: name,
            backendIdentifier: backendIdentifier,
            remoteId: remoteId,
            sessionRoutingID: terminalSessionIdentifier,
            status: status,
            repoName: sourceRepo?.name,
            repoRemoteURL: sourceRepo?.remoteURL,
            sshMetadata: sshMetadata,
            composeMetadata: composeMetadata
        )
    }

    public var localWorkspaceContext: LocalWorkspaceContext? {
        guard let localDirectoryURL else { return nil }
        return LocalWorkspaceContext(
            workspaceID: id,
            directoryURL: localDirectoryURL
        )
    }

    public var status: WorkspaceStatus {
        get { WorkspaceStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    public var sshMetadata: SSHWorkspaceMetadata? {
        get {
            remoteMetadataPayload?.ssh
        }
        set {
            updateRemoteMetadata { $0.ssh = newValue }
        }
    }

    public var kubernetesMetadata: KubernetesWorkspaceMetadata? {
        get {
            remoteMetadataPayload?.kubernetes
        }
        set {
            updateRemoteMetadata { $0.kubernetes = newValue }
        }
    }

    public var composeMetadata: ComposeWorkspaceMetadata? {
        get {
            remoteMetadataPayload?.compose
        }
        set {
            updateRemoteMetadata { $0.compose = newValue }
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        sourceRepo: Repo,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        status: WorkspaceStatus = .active,
        gitBranch: String? = nil,
        archivedAt: Date? = nil,
        isAdopted: Bool = false,
        pinOrder: Int? = nil,
        note: String? = nil,
        defaultAgentCommand: String? = nil,
        backendIdentifier: String = "local",
        remoteId: String? = nil,
        sessionRoutingID: String? = nil,
        backendMetadataRaw: String = "",
        remoteMetadataJSON: String = ""
    ) {
        self.id = id
        self.name = name
        self.path = path.path
        self.sourceRepo = sourceRepo
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.statusRaw = status.rawValue
        self.gitBranch = gitBranch
        self.archivedAt = archivedAt
        self.isAdopted = isAdopted
        self.pinOrder = pinOrder
        self.note = WorkspaceNote.normalized(note)
        self.defaultAgentCommand = defaultAgentCommand
        self.backendIdentifier = backendIdentifier
        self.remoteId = remoteId
        self.sessionRoutingID = sessionRoutingID
        self.backendMetadataRaw = backendMetadataRaw
        self.remoteMetadataJSON = remoteMetadataJSON
    }

    public func decodeBackendMetadata<T: Decodable>(_ type: T.Type) -> T? {
        guard !backendMetadataRaw.isEmpty,
            let data = backendMetadataRaw.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func encodeBackendMetadata<T: Encodable>(_ metadata: T?) {
        guard let metadata else {
            backendMetadataRaw = ""
            return
        }

        guard let data = try? JSONEncoder().encode(metadata),
            let rawValue = String(data: data, encoding: .utf8)
        else {
            backendMetadataRaw = ""
            return
        }

        backendMetadataRaw = rawValue
    }

    @Transient private var _cachedRemoteMetadata: WorkspaceRemoteMetadataPayload??
    @Transient private var _cachedRemoteMetadataSource: String = ""

    private var remoteMetadataPayload: WorkspaceRemoteMetadataPayload? {
        get {
            let trimmedJSON = remoteMetadataJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedJSON == _cachedRemoteMetadataSource, let cached = _cachedRemoteMetadata {
                return cached
            }
            let result: WorkspaceRemoteMetadataPayload?
            if trimmedJSON.isEmpty {
                result = nil
            } else if let data = trimmedJSON.data(using: .utf8),
                let payload = try? JSONDecoder().decode(WorkspaceRemoteMetadataPayload.self, from: data),
                !payload.isEmpty
            {
                result = payload
            } else {
                result = nil
            }
            _cachedRemoteMetadataSource = trimmedJSON
            _cachedRemoteMetadata = .some(result)
            return result
        }
        set {
            guard let newValue else {
                remoteMetadataJSON = ""
                return
            }

            guard
                let data = try? JSONEncoder().encode(newValue),
                let json = String(data: data, encoding: .utf8)
            else {
                remoteMetadataJSON = ""
                return
            }

            remoteMetadataJSON = json
        }
    }

    private func updateRemoteMetadata(_ update: (inout WorkspaceRemoteMetadataPayload) -> Void) {
        var payload = remoteMetadataPayload ?? WorkspaceRemoteMetadataPayload()
        update(&payload)
        remoteMetadataPayload = payload.isEmpty ? nil : payload
    }
}

public enum WebSourceOwnershipScope: Hashable, Codable, Sendable {
    case global
    case repo(UUID)
    case workspace(UUID)
}

public enum BackendKind: Codable, Sendable, Equatable {
    case local
    case lume
    case daytona
    case ssh
    /// A provider ID not in this enum — preserves the raw string for registry lookups.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "local": self = .local
        case "lume": self = .lume
        case "daytona": self = .daytona
        case "ssh": self = .ssh
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .local: return "local"
        case .lume: return "lume"
        case .daytona: return "daytona"
        case .ssh: return "ssh"
        case .unknown(let id): return id
        }
    }

    public var isLocal: Bool { self == .local }
}

public enum WorkspaceStatus: String, Codable, CaseIterable, Sendable {
    case provisioning
    case active
    case stopped
    case archived

    public var label: String {
        switch self {
        case .provisioning: return "Provisioning"
        case .active: return "Active"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }
}

// MARK: - File Change (Runtime only, not persisted)

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: GitStatus

    public init(path: String, status: GitStatus) {
        self.path = path
        self.status = status
    }
}

public enum GitStatus: String, CaseIterable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case untracked = "?"
    case renamed = "R"

    public var icon: String {
        switch self {
        case .modified: return "pencil.circle.fill"
        case .added: return "plus.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .untracked: return "questionmark.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .untracked: return .gray
        case .renamed: return .blue
        }
    }
}

// MARK: - File Node (for file tree display)

public struct FileNode: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public var children: [FileNode]?

    public init(name: String, path: String, isDirectory: Bool, children: [FileNode]? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }

    public var icon: String {
        if isDirectory {
            return "folder.fill"
        }

        // File type icons based on extension
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "doc.text"
        case "py": return "doc.text"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        case "html", "htm": return "globe"
        case "css", "scss": return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "pdf": return "doc.fill"
        case "zip", "tar", "gz": return "doc.zipper"
        default: return "doc"
        }
    }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}
