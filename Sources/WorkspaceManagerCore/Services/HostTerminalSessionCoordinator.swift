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

    public func normalized() -> HostTerminalSessionKey {
        switch self {
        case .defaultHome:
            return .defaultHome
        case .repoPath(let path):
            return .repoPath(Self.normalizedPath(path))
        case .hostPath(let path):
            return .hostPath(Self.normalizedPath(path))
        case .backendSession:
            return self
        }
    }

    private static let normalizationCacheLock = NSLock()
    nonisolated(unsafe) private static var normalizationCache: [String: String] = [:]

    /// Key normalization runs per sidebar row per render and per coordinator
    /// sweep; symlink resolution is an `lstat` per path component, so the
    /// resolved form is memoized (#1347 B1). Stale only if the filesystem
    /// changes under an already-seen raw path. Resolution happens outside the
    /// lock so a slow disk never serializes unrelated lookups. Public so
    /// render paths that compare directory paths share the one process-wide
    /// memo instead of resolving per body evaluation.
    public static func normalizedPath(_ path: String) -> String {
        normalizationCacheLock.lock()
        if let cached = normalizationCache[path] {
            normalizationCacheLock.unlock()
            return cached
        }
        normalizationCacheLock.unlock()

        let normalized = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        normalizationCacheLock.lock()
        if normalizationCache.count >= 4096 {
            normalizationCache.removeAll(keepingCapacity: true)
        }
        normalizationCache[path] = normalized
        normalizationCacheLock.unlock()
        return normalized
    }
}

extension HostTerminalSessionKey: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case providerID
        case instanceID
    }

    private enum Kind: String, Codable {
        case defaultHome
        case repoPath
        case hostPath
        case backendSession
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .defaultHome:
            self = .defaultHome
        case .repoPath:
            self = .repoPath(try container.decode(String.self, forKey: .path))
        case .hostPath:
            self = .hostPath(try container.decode(String.self, forKey: .path))
        case .backendSession:
            self = .backendSession(
                providerID: try container.decode(String.self, forKey: .providerID),
                instanceID: try container.decode(String.self, forKey: .instanceID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultHome:
            try container.encode(Kind.defaultHome, forKey: .kind)
        case .repoPath(let path):
            try container.encode(Kind.repoPath, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .hostPath(let path):
            try container.encode(Kind.hostPath, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .backendSession(let providerID, let instanceID):
            try container.encode(Kind.backendSession, forKey: .kind)
            try container.encode(providerID, forKey: .providerID)
            try container.encode(instanceID, forKey: .instanceID)
        }
    }
}

public struct HostTerminalSession: Identifiable, Hashable, Sendable {
    /// What the surface does with `initialCommand` once it reaches the shell.
    ///
    /// Restore uses `.prefill`: reconnecting to a live process is free, but starting
    /// an agent costs memory and tokens, so the command waits at the prompt for the
    /// user to press Return. `.execute` is for callers that mean "run this now".
    public enum InitialCommandDelivery: String, Codable, Sendable, Hashable {
        case prefill
        case execute
    }

    public let id: UUID
    public let key: HostTerminalSessionKey
    public let directoryPath: String
    /// Custom shell command override (e.g. SSH to remote sandbox). When set, the terminal
    /// launches this command instead of the user's default shell, on a fixed PATH.
    public let customCommand: String?
    /// Agent command to run as this directory-backed surface's initial process (e.g.
    /// `claude --resume <id>` for cold-start restore). Unlike `customCommand`, it runs
    /// through the login-shell/tmux path (correct PATH, hook env) and does not mark the
    /// session remote. `nil` for a plain shell.
    public let initialCommand: String?
    /// Whether `initialCommand` is typed and left at the prompt or typed and run.
    /// Meaningless when `initialCommand` is `nil`.
    public let initialCommandDelivery: InitialCommandDelivery
    /// Chosen tmux session name when it must differ from the directory derivation:
    /// a split pane's disambiguated name, or the probed name a restore reattaches
    /// to. `nil` means the default directory-derived name.
    public let tmuxSessionNameOverride: String?

    public var directoryURL: URL {
        URL(fileURLWithPath: directoryPath)
    }

    /// The tmux session name this surface launches on in `.tmuxPerSession` mode:
    /// the override when one was chosen, otherwise the directory derivation.
    public var effectiveTmuxSessionName: String {
        tmuxSessionNameOverride ?? TmuxSessionNaming.defaultName(for: directoryURL)
    }

    public var isRemote: Bool {
        customCommand != nil
    }

    public init(
        id: UUID = UUID(),
        key: HostTerminalSessionKey,
        directory: URL,
        customCommand: String? = nil,
        initialCommand: String? = nil,
        initialCommandDelivery: InitialCommandDelivery = .execute,
        tmuxSessionNameOverride: String? = nil
    ) {
        self.id = id
        self.key = key.normalized()
        self.directoryPath = Self.normalize(directory).path
        self.customCommand = customCommand
        self.initialCommand = initialCommand
        self.initialCommandDelivery = initialCommandDelivery
        self.tmuxSessionNameOverride = tmuxSessionNameOverride
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
    public private(set) var activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID]

    public init(
        sessions: [HostTerminalSession] = [],
        activeSessionID: UUID? = nil,
        activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID] = [:]
    ) {
        self.sessions = sessions
        self.activeSessionID = nil
        self.activeSessionIDByScopeKey = [:]

        let validSessionIDs = Set(sessions.map(\.id))
        for (scopeKey, sessionID) in activeSessionIDByScopeKey
        where validSessionIDs.contains(sessionID)
            && sessions.contains(where: { $0.id == sessionID && $0.key == scopeKey.normalized() })
        {
            self.activeSessionIDByScopeKey[scopeKey.normalized()] = sessionID
        }

        let restoredScopeKeys = Set(self.activeSessionIDByScopeKey.keys)
        for session in sessions where !restoredScopeKeys.contains(session.key) {
            self.activeSessionIDByScopeKey[session.key] = session.id
        }

        if let activeSessionID, validSessionIDs.contains(activeSessionID) {
            setActiveSessionID(activeSessionID)
        } else {
            self.activeSessionID = sessions.last?.id
            if let activeSessionID = self.activeSessionID {
                setActiveSessionID(activeSessionID)
            }
        }
    }

    public var activeScopeKey: HostTerminalSessionKey? {
        activeSessionID.flatMap(session(withID:))?.key
    }

    public func sessions(inScope scopeKey: HostTerminalSessionKey?) -> [HostTerminalSession] {
        guard let normalizedScopeKey = scopeKey?.normalized() else { return [] }
        return sessions.filter { $0.key == normalizedScopeKey }
    }

    @discardableResult
    public mutating func activate(
        key: HostTerminalSessionKey,
        directory: URL,
        customCommand: String? = nil,
        initialCommand: String? = nil
    ) -> HostTerminalSessionActivationResult {
        let normalizedDirectory = HostTerminalSession.normalize(directory)
        let normalizedPath = normalizedDirectory.path
        let normalizedKey = key.normalized()

        if let activeScopeSession = activeSessionIDByScopeKey[normalizedKey].flatMap(session(withID:)) {
            setActiveSessionID(activeScopeSession.id)
            return HostTerminalSessionActivationResult(session: activeScopeSession, created: false)
        }

        if let existing = sessions.first(where: { $0.key == normalizedKey }) {
            setActiveSessionID(existing.id)
            return HostTerminalSessionActivationResult(session: existing, created: false)
        }

        if shouldReuseByDirectoryPath(for: normalizedKey),
            let existing = sessions.first(where: {
                shouldReuseByDirectoryPath(for: $0.key) && $0.directoryPath == normalizedPath
            })
        {
            setActiveSessionID(existing.id)
            return HostTerminalSessionActivationResult(session: existing, created: false)
        }

        let session = HostTerminalSession(
            key: normalizedKey,
            directory: normalizedDirectory,
            customCommand: customCommand,
            initialCommand: initialCommand
        )
        sessions.append(session)
        setActiveSessionID(session.id)
        return HostTerminalSessionActivationResult(session: session, created: true)
    }

    @discardableResult
    public mutating func ensureSession(
        key: HostTerminalSessionKey,
        directory: URL,
        customCommand: String? = nil,
        initialCommand: String? = nil
    ) -> HostTerminalSessionActivationResult {
        let normalizedDirectory = HostTerminalSession.normalize(directory)
        let normalizedPath = normalizedDirectory.path
        let normalizedKey = key.normalized()

        if let activeScopeSession = activeSessionIDByScopeKey[normalizedKey].flatMap(session(withID:)) {
            return HostTerminalSessionActivationResult(session: activeScopeSession, created: false)
        }

        if let existing = sessions.first(where: { $0.key == normalizedKey }) {
            activeSessionIDByScopeKey[normalizedKey] = existing.id
            return HostTerminalSessionActivationResult(session: existing, created: false)
        }

        if shouldReuseByDirectoryPath(for: normalizedKey),
            let existing = sessions.first(where: {
                shouldReuseByDirectoryPath(for: $0.key) && $0.directoryPath == normalizedPath
            })
        {
            activeSessionIDByScopeKey[normalizedKey] = existing.id
            return HostTerminalSessionActivationResult(session: existing, created: false)
        }

        let session = HostTerminalSession(
            key: normalizedKey,
            directory: normalizedDirectory,
            customCommand: customCommand,
            initialCommand: initialCommand
        )
        sessions.append(session)
        activeSessionIDByScopeKey[normalizedKey] = session.id
        if activeSessionID == nil {
            setActiveSessionID(session.id)
        }
        return HostTerminalSessionActivationResult(session: session, created: true)
    }

    @discardableResult
    public mutating func activate(sessionID: UUID) -> HostTerminalSession? {
        guard let session = session(withID: sessionID) else { return nil }
        setActiveSessionID(session.id)
        return session
    }

    /// Always-create activation for restore wiring. Each restore surface maps 1:1 to a
    /// recorded continuity row and the owned scope is retired before restore runs, so
    /// `activate`'s key-reuse would collapse sibling pane rows into one session and drop
    /// the later rows' initial commands and recorded tmux targets (#1232).
    @discardableResult
    /// Creates a session, optionally under an identity that already exists outside
    /// this run.
    ///
    /// `adoptedID` belongs to a surface rejoining a process tree that outlived the
    /// app: the shells inside a surviving tmux session still export the previous
    /// run's `WORKSPACES_HOST_SESSION_ID`, so minting a fresh identity leaves the
    /// tile and its own pane disagreeing about who they are, and every agent
    /// update the pane posts lands on an id nothing here owns (#1397). An id that
    /// is already live cannot be adopted — two tiles sharing one identity would
    /// merge their status — and falls back to a fresh one.
    public mutating func createSession(
        key: HostTerminalSessionKey,
        directory: URL,
        initialCommand: String? = nil,
        initialCommandDelivery: HostTerminalSession.InitialCommandDelivery = .execute,
        tmuxSessionNameOverride: String? = nil,
        adoptedID: UUID? = nil
    ) -> HostTerminalSession {
        let resolvedID: UUID
        if let adoptedID, !sessions.contains(where: { $0.id == adoptedID }) {
            resolvedID = adoptedID
        } else {
            resolvedID = UUID()
        }
        let session = HostTerminalSession(
            id: resolvedID,
            key: key,
            directory: directory,
            initialCommand: initialCommand,
            initialCommandDelivery: initialCommandDelivery,
            tmuxSessionNameOverride: tmuxSessionNameOverride
        )
        sessions.append(session)
        setActiveSessionID(session.id)
        return session
    }

    @discardableResult
    public mutating func createTab(from source: HostTerminalSession) -> HostTerminalSession {
        let session = HostTerminalSession(
            key: source.key,
            directory: source.directoryURL,
            customCommand: source.customCommand
        )
        sessions.append(session)
        setActiveSessionID(session.id)
        return session
    }

    @discardableResult
    public mutating func activateAdjacent(to sessionID: UUID, offset: Int) -> HostTerminalSession? {
        guard let currentSession = session(withID: sessionID) else {
            return nil
        }

        let scopedSessions = sessions(inScope: currentSession.key)
        guard !scopedSessions.isEmpty,
            let currentIndex = scopedSessions.firstIndex(where: { $0.id == sessionID })
        else {
            return nil
        }

        let nextIndex = wrappedIndex(currentIndex + offset, count: scopedSessions.count)
        let session = scopedSessions[nextIndex]
        setActiveSessionID(session.id)
        return session
    }

    @discardableResult
    public mutating func activateTab(atOneBasedIndex index: Int) -> HostTerminalSession? {
        let scopedSessions = sessions(inScope: activeScopeKey)
        guard !scopedSessions.isEmpty else { return nil }
        let clampedIndex = min(max(index - 1, 0), scopedSessions.count - 1)
        let session = scopedSessions[clampedIndex]
        setActiveSessionID(session.id)
        return session
    }

    @discardableResult
    public mutating func activateLastTab() -> HostTerminalSession? {
        guard let session = sessions(inScope: activeScopeKey).last else { return nil }
        setActiveSessionID(session.id)
        return session
    }

    @discardableResult
    public mutating func moveTab(sessionID: UUID, offset: Int) -> Bool {
        guard let currentSession = session(withID: sessionID) else { return false }

        let scopedIndices = sessions.indices.filter { sessions[$0].key == currentSession.key }
        guard scopedIndices.count > 1,
            offset != 0,
            let currentGlobalIndex = sessions.firstIndex(where: { $0.id == sessionID }),
            let currentScopedIndex = scopedIndices.firstIndex(of: currentGlobalIndex)
        else {
            return false
        }

        let nextScopedIndex = wrappedIndex(currentScopedIndex + offset, count: scopedIndices.count)
        let session = sessions.remove(at: currentGlobalIndex)
        let remainingScopeIndices = sessions.indices.filter { sessions[$0].key == currentSession.key }
        let insertionIndex: Int
        if nextScopedIndex >= remainingScopeIndices.count {
            insertionIndex = remainingScopeIndices.last.map { sessions.index(after: $0) } ?? sessions.endIndex
        } else {
            insertionIndex = remainingScopeIndices[nextScopedIndex]
        }

        sessions.insert(session, at: insertionIndex)
        setActiveSessionID(session.id)
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
            setActiveSessionID(sessions.last?.id)
        }

        for sessionID in removedIDs {
            removeActiveScopeReference(for: sessionID)
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
            let sameScopeFallback = sessions.last(where: { $0.key == removed.key })
            setActiveSessionID(sameScopeFallback?.id ?? sessions.last?.id)
        }
        removeActiveScopeReference(for: sessionID, removedScopeKey: removed.key)

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

    private func session(withID sessionID: UUID) -> HostTerminalSession? {
        sessions.first(where: { $0.id == sessionID })
    }

    private mutating func setActiveSessionID(_ sessionID: UUID?) {
        activeSessionID = sessionID
        guard let sessionID, let session = session(withID: sessionID) else { return }
        activeSessionIDByScopeKey[session.key] = sessionID
    }

    private mutating func removeActiveScopeReference(
        for sessionID: UUID,
        removedScopeKey: HostTerminalSessionKey? = nil
    ) {
        let affectedScopeKeys = activeSessionIDByScopeKey.compactMap { scopeKey, activeSessionID in
            activeSessionID == sessionID ? scopeKey : nil
        }

        for scopeKey in affectedScopeKeys {
            activeSessionIDByScopeKey.removeValue(forKey: scopeKey)
            if let fallbackSession = sessions.last(where: { $0.key == scopeKey }) {
                activeSessionIDByScopeKey[scopeKey] = fallbackSession.id
            }
        }

        if let removedScopeKey,
            activeSessionIDByScopeKey[removedScopeKey] == nil,
            let fallbackSession = sessions.last(where: { $0.key == removedScopeKey })
        {
            activeSessionIDByScopeKey[removedScopeKey] = fallbackSession.id
        }
    }
}
