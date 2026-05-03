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
    /// Provider-backed session keyed by provider identifier and remote instance ID.
    case backendSession(providerID: String, instanceID: String)

    public var debugDescription: String {
        switch self {
        case .defaultHome:
            return "defaultHome"
        case .repoPath(let path):
            return "repoPath(\(path))"
        case .hostPath(let path):
            return "hostPath(\(path))"
        case .backendSession(let providerID, let instanceID):
            return "backendSession(\(providerID), \(instanceID))"
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
        case .backendSession:
            return self
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
    /// Custom shell command override (e.g. SSH to remote sandbox). When set, the terminal
    /// launches this command instead of the user's default shell.
    public let customCommand: String?

    public var directoryURL: URL {
        URL(fileURLWithPath: directoryPath)
    }

    public var isRemote: Bool {
        customCommand != nil
    }

    public init(id: UUID = UUID(), key: HostTerminalSessionKey, directory: URL, customCommand: String? = nil) {
        self.id = id
        self.key = key.normalized()
        self.directoryPath = Self.normalize(directory).path
        self.customCommand = customCommand
    }

    static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public struct HostTerminalSessionActivationResult: Sendable {
    public let session: HostTerminalSession
    public let created: Bool
}

public struct HostTerminalSessionPresentation: Sendable, Equatable {
    public let liveRepoPaths: Set<String>
    public let activeRepoPath: String?
    public let hasDefaultHomeSession: Bool
    public let isDefaultHomeSessionActive: Bool

    public init(
        liveRepoPaths: Set<String> = [],
        activeRepoPath: String? = nil,
        hasDefaultHomeSession: Bool = false,
        isDefaultHomeSessionActive: Bool = false
    ) {
        self.liveRepoPaths = liveRepoPaths
        self.activeRepoPath = activeRepoPath
        self.hasDefaultHomeSession = hasDefaultHomeSession
        self.isDefaultHomeSessionActive = isDefaultHomeSessionActive
    }
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
        directory: URL,
        customCommand: String? = nil
    ) -> HostTerminalSessionActivationResult {
        let normalizedDirectory = HostTerminalSession.normalize(directory)
        let normalizedPath = normalizedDirectory.path
        let normalizedKey = key.normalized()

        if let existing = sessions.first(where: { $0.key == normalizedKey }) {
            activeSessionID = existing.id
            return HostTerminalSessionActivationResult(session: existing, created: false)
        }

        if shouldReuseByDirectoryPath(for: normalizedKey),
            let existing = sessions.first(where: {
                shouldReuseByDirectoryPath(for: $0.key) && $0.directoryPath == normalizedPath
            })
        {
            activeSessionID = existing.id
            return HostTerminalSessionActivationResult(session: existing, created: false)
        }

        let session = HostTerminalSession(
            key: normalizedKey,
            directory: normalizedDirectory,
            customCommand: customCommand
        )
        sessions.append(session)
        activeSessionID = session.id
        return HostTerminalSessionActivationResult(session: session, created: true)
    }

    @discardableResult
    public mutating func createTab(from source: HostTerminalSession) -> HostTerminalSession {
        let session = HostTerminalSession(
            key: source.key,
            directory: source.directoryURL,
            customCommand: source.customCommand
        )
        sessions.append(session)
        activeSessionID = session.id
        return session
    }

    @discardableResult
    public mutating func activateAdjacent(to sessionID: UUID, offset: Int) -> HostTerminalSession? {
        guard !sessions.isEmpty,
            let currentIndex = sessions.firstIndex(where: { $0.id == sessionID })
        else {
            return nil
        }

        let nextIndex = wrappedIndex(currentIndex + offset, count: sessions.count)
        let session = sessions[nextIndex]
        activeSessionID = session.id
        return session
    }

    @discardableResult
    public mutating func activateTab(atOneBasedIndex index: Int) -> HostTerminalSession? {
        guard !sessions.isEmpty else { return nil }
        let clampedIndex = min(max(index - 1, 0), sessions.count - 1)
        let session = sessions[clampedIndex]
        activeSessionID = session.id
        return session
    }

    @discardableResult
    public mutating func activateLastTab() -> HostTerminalSession? {
        guard let session = sessions.last else { return nil }
        activeSessionID = session.id
        return session
    }

    @discardableResult
    public mutating func moveTab(sessionID: UUID, offset: Int) -> Bool {
        guard sessions.count > 1,
            offset != 0,
            let currentIndex = sessions.firstIndex(where: { $0.id == sessionID })
        else {
            return false
        }

        let session = sessions.remove(at: currentIndex)
        let nextIndex = wrappedIndex(currentIndex + offset, count: sessions.count + 1)
        sessions.insert(session, at: nextIndex)
        activeSessionID = session.id
        return true
    }

    private func wrappedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index % count + count) % count
    }

    private func shouldReuseByDirectoryPath(for key: HostTerminalSessionKey) -> Bool {
        switch key {
        case .backendSession:
            return false
        case .defaultHome, .repoPath, .hostPath:
            return true
        }
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

    @discardableResult
    public mutating func remove(sessionID: UUID) -> HostTerminalSession? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return nil
        }

        let removed = sessions.remove(at: index)
        if activeSessionID == sessionID {
            activeSessionID = sessions.last?.id
        }

        return removed
    }

    public var presentation: HostTerminalSessionPresentation {
        let liveRepoPaths = Set<String>(
            sessions.compactMap { session in
                guard case .repoPath(let path) = session.key else { return nil }
                return path
            }
        )

        let activeSession = activeSessionID.flatMap { id in
            sessions.first(where: { $0.id == id })
        }

        let activeRepoPath: String?
        if let activeSession, case .repoPath(let path) = activeSession.key {
            activeRepoPath = path
        } else {
            activeRepoPath = nil
        }

        let hasDefaultHomeSession = sessions.contains(where: { $0.key == .defaultHome })
        let isDefaultHomeSessionActive = activeSession?.key == .defaultHome

        return HostTerminalSessionPresentation(
            liveRepoPaths: liveRepoPaths,
            activeRepoPath: activeRepoPath,
            hasDefaultHomeSession: hasDefaultHomeSession,
            isDefaultHomeSessionActive: isDefaultHomeSessionActive
        )
    }
}
