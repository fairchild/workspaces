//
//  HostTerminalSessionCoordinator.swift
//  WorkspaceManagerCore
//
//  Canonical session identity and lifecycle management for host terminals.
//

import Foundation

public enum HostTerminalSessionKey: Hashable, Sendable, CustomDebugStringConvertible {
    case defaultHome
    case repoPath(String)
    case hostPath(String)

    public var debugDescription: String {
        switch self {
        case .defaultHome:
            return "defaultHome"
        case .repoPath(let path):
            return "repoPath(\(path))"
        case .hostPath(let path):
            return "hostPath(\(path))"
        }
    }

    func normalized() -> HostTerminalSessionKey {
        switch self {
        case .defaultHome:
            return .defaultHome
        case .repoPath(let path):
            return .repoPath(Self.normalizePath(path))
        case .hostPath(let path):
            return .hostPath(Self.normalizePath(path))
        }
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

public struct HostTerminalSession: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let key: HostTerminalSessionKey
    public let directoryPath: String

    public var directoryURL: URL {
        URL(fileURLWithPath: directoryPath)
    }

    public init(id: UUID = UUID(), key: HostTerminalSessionKey, directory: URL) {
        self.id = id
        self.key = key.normalized()
        self.directoryPath = Self.normalize(directory).path
    }

    static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public struct HostTerminalSessionActivationResult: Sendable {
    public let session: HostTerminalSession
    public let created: Bool
}

public struct HostTerminalSessionCoordinator: Sendable {
    public private(set) var sessions: [HostTerminalSession]
    public private(set) var activeSessionID: UUID?

    public init(
        sessions: [HostTerminalSession] = [],
        activeSessionID: UUID? = nil
    ) {
        self.sessions = sessions
        self.activeSessionID = activeSessionID
    }

    @discardableResult
    public mutating func activate(
        key: HostTerminalSessionKey,
        directory: URL
    ) -> HostTerminalSessionActivationResult {
        let normalizedDirectory = HostTerminalSession.normalize(directory)
        let normalizedPath = normalizedDirectory.path
        let normalizedKey = key.normalized()

        if let existing = sessions.first(where: { $0.key == normalizedKey }) {
            activeSessionID = existing.id
            return HostTerminalSessionActivationResult(session: existing, created: false)
        }

        if let existing = sessions.first(where: { $0.directoryPath == normalizedPath }) {
            activeSessionID = existing.id
            return HostTerminalSessionActivationResult(session: existing, created: false)
        }

        let session = HostTerminalSession(
            key: normalizedKey,
            directory: normalizedDirectory
        )
        sessions.append(session)
        activeSessionID = session.id
        return HostTerminalSessionActivationResult(session: session, created: true)
    }

    @discardableResult
    public mutating func pruneRepoSessions(validRepoPaths: Set<String>) -> [UUID] {
        let normalizedValidPaths = Set(
            validRepoPaths.map {
                URL(fileURLWithPath: $0)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
            }
        )

        let removedIDs = sessions.compactMap { session -> UUID? in
            guard case .repoPath(let repoPath) = session.key else { return nil }
            return normalizedValidPaths.contains(repoPath) ? nil : session.id
        }

        guard !removedIDs.isEmpty else { return [] }
        let removedSet = Set(removedIDs)
        sessions.removeAll { removedSet.contains($0.id) }

        if let activeSessionID, removedSet.contains(activeSessionID) {
            self.activeSessionID = sessions.last?.id
        }

        return removedIDs
    }
}
