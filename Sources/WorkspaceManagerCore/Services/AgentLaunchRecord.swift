//
//  AgentLaunchRecord.swift
//  WorkspaceManagerCore
//
//  What `ws launch` remembers about a session, on disk, so the session can be found again
//  after whatever ran it is gone: a tmux server does not survive a reboot, and the app may
//  never have been open. One file per handle, so launchers running in parallel cannot lose
//  each other's writes the way they could in one shared state file.
//

import Foundation

public struct AgentLaunchRecord: Codable, Sendable, Equatable {
    public let handle: String
    public let workspacePath: String
    public let socketLabel: String
    public let launchedAt: Date
    /// `nil` when the command was not a plain `claude` invocation: the session ran, but no
    /// conversation can be named for it.
    public let identity: AgentLaunchIdentity?
    /// When `ws resume` last brought the conversation back. Writing it is also what tells a
    /// watching app to rejoin the session.
    public var resumedAt: Date?

    public init(
        handle: String,
        workspacePath: String,
        socketLabel: String,
        launchedAt: Date,
        identity: AgentLaunchIdentity?,
        resumedAt: Date? = nil
    ) {
        self.handle = handle
        self.workspacePath = workspacePath
        self.socketLabel = socketLabel
        self.launchedAt = launchedAt
        self.identity = identity
        self.resumedAt = resumedAt
    }

    /// Whether the directory at the recorded path is the one launched into. A workspace can
    /// be archived and another made at the same path, and its conversation is no part of
    /// that one. Stored times carry whole seconds, so a workspace made in the launch's own
    /// second has to count.
    public var isForWorkspaceOnDisk: Bool {
        guard
            let created = (try? FileManager.default.attributesOfItem(atPath: workspacePath))?[.creationDate] as? Date
        else { return false }
        return created.timeIntervalSince(launchedAt) < 1
    }
}

/// An exclusive claim on one conversation, for the span between seeing that nothing holds it
/// and a new holder being visible. The kernel drops it when the process ends, so a crashed
/// resume leaves nothing behind.
public final class AgentConversationLock: Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public func release() {
        close(descriptor)
    }
}

extension AgentLaunchRecordStore {
    /// The command that would continue the conversation recorded under this tmux name, or
    /// `nil` when there is nothing to continue: no record, a command that named no
    /// conversation, a later workspace at the same path, a conversation still held by a
    /// process, or one that never took a turn.
    public func resumeCommand(
        socketLabel: String,
        tmuxSessionName: String,
        processListing: String?,
        resumability: ClaudeTranscriptResumability
    ) -> String? {
        guard let record = load(socketLabel: socketLabel, handle: tmuxSessionName),
            let identity = record.identity,
            record.isForWorkspaceOnDisk,
            let processListing,
            AgentSessionInspection.conversationHolders(identity.conversationID, processListing: processListing).isEmpty,
            let transcript = resumability.existingTranscriptURL(
                agentSessionID: identity.conversationID,
                launchDirectory: record.workspacePath
            )
        else { return nil }
        return AgentLaunchCommand.claudeResume(identity: identity, transcript: transcript)
    }
}

/// The directory the CLI keeps its local state in, shared with the app so both read the
/// same launch records.
public enum CLIConfigDirectory {
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("workspaces-cli")
        }
        return
            homeDirectory
            .appendingPathComponent(".config")
            .appendingPathComponent("workspaces-cli")
    }
}

public struct AgentLaunchRecordStore: Sendable {
    public let directory: URL

    public init(directory: URL = CLIConfigDirectory.resolved().appendingPathComponent("launches")) {
        self.directory = directory
    }

    /// Records live under the socket they were launched on: an isolated run's handles
    /// are the same names, and they must not answer for the desktop's sessions.
    public func directory(socketLabel: String) -> URL {
        directory.appendingPathComponent(socketLabel, isDirectory: true)
    }

    public func save(_ record: AgentLaunchRecord) throws {
        guard let url = fileURL(socketLabel: record.socketLabel, handle: record.handle) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: [.atomic])
    }

    public func load(socketLabel: String, handle: String) -> AgentLaunchRecord? {
        guard let url = fileURL(socketLabel: socketLabel, handle: handle) else { return nil }
        return Self.decode(contentsOf: url)
    }

    /// Every record on a socket. An unreadable one is skipped: it can only be a record
    /// nothing can act on.
    public func all(socketLabel: String) -> [AgentLaunchRecord] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory(socketLabel: socketLabel),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap(Self.decode(contentsOf:))
    }

    public enum LockError: Error {
        case held
    }

    /// Waits for the conversation to be free, then claims it. Keyed by conversation rather
    /// than handle, because two handles can name one conversation. The lock files sit
    /// beside the socket directories, where writing them wakes nothing that watches records.
    public func lockConversation(
        _ conversationID: String,
        timeout: Duration = .seconds(30)
    ) async throws -> AgentConversationLock {
        guard UUID(uuidString: conversationID) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let locks = directory.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let path = locks.appendingPathComponent("\(conversationID).lock").path
        // Close-on-exec: a lock stays held for as long as anything that inherited the
        // descriptor runs, and a resume can start a tmux server.
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else {
                close(descriptor)
                throw LockError.held
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                close(descriptor)
                throw error
            }
        }
        return AgentConversationLock(descriptor: descriptor)
    }

    /// A handle becomes a filename, so it has to be one.
    private func fileURL(socketLabel: String, handle: String) -> URL? {
        guard TmuxSessionProbe.isSafeSocketLabel(socketLabel), TmuxSessionProbe.isSafeSocketLabel(handle),
            !handle.hasPrefix(".")
        else { return nil }
        return directory(socketLabel: socketLabel).appendingPathComponent("\(handle).json")
    }

    private static func decode(contentsOf url: URL) -> AgentLaunchRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentLaunchRecord.self, from: data)
    }
}
