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
