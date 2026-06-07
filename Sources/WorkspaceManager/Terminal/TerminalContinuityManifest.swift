//
//  TerminalContinuityManifest.swift
//  WorkspaceManager
//

import Foundation
import WorkspaceManagerCore

struct TerminalContinuityManifest: Codable, Equatable {
    enum TargetKind: String, Codable {
        case home
        case repo
        case workspace
    }

    struct SessionRecord: Codable, Equatable {
        let id: UUID
        let key: HostTerminalSessionKey
        let directoryPath: String
        let customCommand: String?

        init(session: HostTerminalSession) {
            self.id = session.id
            self.key = session.key
            self.directoryPath = session.directoryPath
            self.customCommand = session.customCommand
        }

        func restoredSession(fileManager: FileManager = .default) -> HostTerminalSession? {
            guard isSafeForDirectRestore else {
                return nil
            }
            guard Self.isExistingDirectory(directoryPath, fileManager: fileManager) else {
                return nil
            }

            return HostTerminalSession(
                id: id,
                key: key,
                directory: URL(fileURLWithPath: directoryPath, isDirectory: true),
                customCommand: customCommand
            )
        }

        private var isSafeForDirectRestore: Bool {
            guard customCommand == nil else { return false }
            guard case .backendSession = key else { return true }
            return false
        }

        private static func isExistingDirectory(_ path: String, fileManager: FileManager) -> Bool {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return false
            }
            return isDirectory.boolValue
        }
    }

    struct ScopeActiveRecord: Codable, Equatable {
        let scopeKey: HostTerminalSessionKey
        let sessionID: UUID
    }

    struct HostSessionSnapshot: Equatable {
        let sessions: [HostTerminalSession]
        let activeSessionID: UUID?
        let activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID]
    }

    static let storageKey = "terminalContinuity.manifest.v1"
    static let homeTargetID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let version: Int
    let targetKind: TargetKind
    let targetID: UUID
    let rootPath: String
    let launchPath: String
    let terminalMode: TerminalMultiplexingMode
    let tmuxSessionName: String
    let updatedAt: Date
    let sessionRecords: [SessionRecord]
    let activeSessionID: UUID?
    let activeSessionIDsByScope: [ScopeActiveRecord]

    init(
        targetKind: TargetKind,
        targetID: UUID,
        rootURL: URL,
        launchURL: URL,
        terminalMode: TerminalMultiplexingMode,
        sessions: [HostTerminalSession] = [],
        activeSessionID: UUID? = nil,
        activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID] = [:],
        updatedAt: Date = Date()
    ) {
        let normalizedRoot = Self.normalizedPath(for: rootURL)
        let normalizedLaunch = Self.normalizedPath(for: launchURL)

        self.version = 2
        self.targetKind = targetKind
        self.targetID = targetID
        self.rootPath = normalizedRoot
        self.launchPath = normalizedLaunch
        self.terminalMode = terminalMode
        self.tmuxSessionName = GhosttyTerminalConfig.tmuxSessionName(
            for: URL(fileURLWithPath: normalizedLaunch, isDirectory: true)
        )
        self.updatedAt = updatedAt
        self.sessionRecords = sessions.map(SessionRecord.init(session:))
        self.activeSessionID = activeSessionID
        self.activeSessionIDsByScope = activeSessionIDByScopeKey.map { scopeKey, sessionID in
            ScopeActiveRecord(scopeKey: scopeKey, sessionID: sessionID)
        }
        .sorted { lhs, rhs in
            lhs.scopeKey.debugDescription < rhs.scopeKey.debugDescription
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case targetKind
        case targetID
        case rootPath
        case launchPath
        case terminalMode
        case tmuxSessionName
        case updatedAt
        case sessionRecords
        case activeSessionID
        case activeSessionIDsByScope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        targetKind = try container.decode(TargetKind.self, forKey: .targetKind)
        targetID = try container.decode(UUID.self, forKey: .targetID)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        launchPath = try container.decode(String.self, forKey: .launchPath)
        terminalMode = try container.decode(TerminalMultiplexingMode.self, forKey: .terminalMode)
        tmuxSessionName = try container.decode(String.self, forKey: .tmuxSessionName)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sessionRecords = try container.decodeIfPresent([SessionRecord].self, forKey: .sessionRecords) ?? []
        activeSessionID = try container.decodeIfPresent(UUID.self, forKey: .activeSessionID)
        activeSessionIDsByScope =
            try container.decodeIfPresent([ScopeActiveRecord].self, forKey: .activeSessionIDsByScope) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(targetKind, forKey: .targetKind)
        try container.encode(targetID, forKey: .targetID)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encode(launchPath, forKey: .launchPath)
        try container.encode(terminalMode, forKey: .terminalMode)
        try container.encode(tmuxSessionName, forKey: .tmuxSessionName)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(sessionRecords, forKey: .sessionRecords)
        try container.encodeIfPresent(activeSessionID, forKey: .activeSessionID)
        try container.encode(activeSessionIDsByScope, forKey: .activeSessionIDsByScope)
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(from rawValue: String) -> TerminalContinuityManifest? {
        guard !rawValue.isEmpty else { return nil }
        guard let data = rawValue.data(using: .utf8) else { return nil }
        guard let manifest = try? JSONDecoder().decode(TerminalContinuityManifest.self, from: data) else {
            return nil
        }
        guard manifest.version == 1 || manifest.version == 2 else { return nil }
        return manifest
    }

    static func snapshot(
        previous: TerminalContinuityManifest?,
        defaultHomeURL: URL,
        terminalMode: TerminalMultiplexingMode,
        sessions: [HostTerminalSession],
        activeSessionID: UUID?,
        activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID],
        updatedAt: Date = Date()
    ) -> TerminalContinuityManifest {
        let rootURL = URL(
            fileURLWithPath: previous?.rootPath ?? Self.normalizedPath(for: defaultHomeURL),
            isDirectory: true
        )
        let launchURL = URL(
            fileURLWithPath: previous?.launchPath ?? Self.normalizedPath(for: defaultHomeURL),
            isDirectory: true
        )

        return TerminalContinuityManifest(
            targetKind: previous?.targetKind ?? .home,
            targetID: previous?.targetID ?? Self.homeTargetID,
            rootURL: rootURL,
            launchURL: launchURL,
            terminalMode: terminalMode,
            sessions: sessions,
            activeSessionID: activeSessionID,
            activeSessionIDByScopeKey: activeSessionIDByScopeKey,
            updatedAt: updatedAt
        )
    }

    func hostSessionSnapshot(fileManager: FileManager = .default) -> HostSessionSnapshot? {
        let restoredSessions = sessionRecords.compactMap {
            $0.restoredSession(fileManager: fileManager)
        }
        guard !restoredSessions.isEmpty else { return nil }

        let validSessionIDs = Set(restoredSessions.map(\.id))
        var activeByScope: [HostTerminalSessionKey: UUID] = [:]
        for record in activeSessionIDsByScope
        where validSessionIDs.contains(record.sessionID)
            && restoredSessions.contains(where: { $0.id == record.sessionID && $0.key == record.scopeKey })
        {
            activeByScope[record.scopeKey] = record.sessionID
        }

        for session in restoredSessions where activeByScope[session.key] == nil {
            activeByScope[session.key] = session.id
        }

        let restoredActiveSessionID: UUID?
        if let activeSessionID, validSessionIDs.contains(activeSessionID) {
            restoredActiveSessionID = activeSessionID
        } else {
            restoredActiveSessionID = restoredSessions.last?.id
        }

        return HostSessionSnapshot(
            sessions: restoredSessions,
            activeSessionID: restoredActiveSessionID,
            activeSessionIDByScopeKey: activeByScope
        )
    }

    func launchDirectory(
        for targetKind: TargetKind,
        targetID: UUID,
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let normalizedRoot = Self.normalizedPath(for: rootURL)
        guard self.targetKind == targetKind,
            self.targetID == targetID,
            rootPath == normalizedRoot
        else {
            return nil
        }

        if Self.isExistingDirectory(launchPath, fileManager: fileManager),
            Self.path(launchPath, isInside: normalizedRoot)
        {
            return URL(fileURLWithPath: launchPath, isDirectory: true)
        }

        guard Self.isExistingDirectory(normalizedRoot, fileManager: fileManager) else {
            return nil
        }
        return URL(fileURLWithPath: normalizedRoot, isDirectory: true)
    }

    private static func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isExistingDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private static func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }
}
