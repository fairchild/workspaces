//
//  LastCommandStatus.swift
//  WorkspaceManagerCore
//
//  Per-terminal-session "last command" record consumed by the upcoming status
//  sliver UI (M6). Captures what the user can usefully know about the shell
//  command that just finished — its line, its exit code, when it started and
//  ended — without forcing the producer to always know all of them.
//
//  Producer contract is intentionally tolerant: any field may be unknown, and
//  `isRunning` is true exactly when `endedAt` is nil. Producers should publish
//  `started(...)` when they observe the command begin (OSC 133 ;B, shell hook,
//  or heuristic), and `ended(...)` when they observe the command finish
//  (OSC 133 ;D, shell hook, idle-prompt return).
//

import Foundation

public struct LastCommandStatus: Equatable, Sendable {
    /// Best-effort literal command line as typed at the prompt. `nil` when the
    /// producer cannot capture it (e.g. an OSC 133 ;D arrives without ;B
    /// having carried a command, or the heuristic path has no shell hook).
    public let commandLine: String?

    /// Exit code reported by the shell. `nil` while the command is still
    /// running, or when the producer can detect "command ended" but not the
    /// numeric status (heuristic path).
    public let exitCode: Int?

    /// Wall-clock start time as observed by the producer.
    public let startedAt: Date

    /// Wall-clock end time. `nil` while running.
    public let endedAt: Date?

    public init(
        commandLine: String?,
        exitCode: Int?,
        startedAt: Date,
        endedAt: Date?
    ) {
        self.commandLine = commandLine
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public var isRunning: Bool {
        endedAt == nil
    }

    /// `true` for exit code 0, `false` for any non-zero exit, `nil` if the
    /// command is still running or the producer could not capture the code.
    public var isSuccess: Bool? {
        exitCode.map { $0 == 0 }
    }

    /// Convenience constructor for a freshly-started command with no exit
    /// information yet.
    public static func started(
        commandLine: String?,
        at startedAt: Date
    ) -> LastCommandStatus {
        LastCommandStatus(
            commandLine: commandLine,
            exitCode: nil,
            startedAt: startedAt,
            endedAt: nil
        )
    }

    /// Convenience for transitioning a running status into an ended one. If
    /// `self` is not running this is a no-op transform: the existing end time
    /// and exit code are preserved.
    public func ending(
        exitCode: Int?,
        at endedAt: Date
    ) -> LastCommandStatus {
        guard isRunning else { return self }
        return LastCommandStatus(
            commandLine: commandLine,
            exitCode: exitCode,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }
}
