//
//  LastCommandStatusRegistry.swift
//  WorkspaceManagerCore
//
//  Per-terminal-session @Published map of `LastCommandStatus`. The Status Sliver
//  view (M6.chg) reads this to render the prompt-context bar (✓/✗ + exit +
//  duration). Mirrors `WorkspaceStatusAggregator`'s @MainActor / ObservableObject
//  shape so views can subscribe consistently.
//
//  This registry does NOT itself read PTY data. Producers (a future libghostty
//  OSC 133 forwarder, a shell-side PROMPT hook over a socket, or anything else
//  capable of observing prompt boundaries) call `ingest(markers:for:at:)` with
//  parsed `CommandMarker`s and a session id. The registry collapses the
//  prompt → command → end transitions into a single observable
//  `LastCommandStatus` per session.
//
//  Until a producer is wired, this class ships as the public API contract: the
//  view layer can build against `statusByTerminalSession` today and the producer can
//  land in a follow-up without touching the view.
//

import Combine
import Foundation

@MainActor
public final class LastCommandStatusRegistry: ObservableObject {
    @Published public private(set) var statusByTerminalSession: [UUID: LastCommandStatus] = [:]

    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Replace the published status for `terminalSessionID`. Use when a producer can
    /// synthesise a full status in one shot (e.g. shell hook delivers a JSON
    /// payload with both command and exit).
    public func setStatus(_ status: LastCommandStatus, for terminalSessionID: UUID) {
        if statusByTerminalSession[terminalSessionID] != status {
            statusByTerminalSession[terminalSessionID] = status
        }
    }

    /// Feed parsed markers in order. `commandLine` is optional and applies to
    /// the next started command — producers that only observe OSC 133 cannot
    /// know the literal line, so they pass `nil`; producers with shell-side
    /// context (a PROMPT hook) pass the captured line.
    public func ingest(
        markers: [CommandMarker],
        for terminalSessionID: UUID,
        commandLine: String? = nil,
        at timestamp: Date? = nil
    ) {
        guard !markers.isEmpty else { return }
        let now = timestamp ?? clock()

        for marker in markers {
            switch marker {
            case .promptStart, .outputStart:
                // ;A and ;C don't change the published status — they're
                // structural in the OSC 133 dance. A prompt start that arrives
                // while a previous command is still "running" implies the
                // shell silently dropped the end; clear it so the UI doesn't
                // show a phantom in-flight command.
                if case .promptStart = marker,
                    let current = statusByTerminalSession[terminalSessionID],
                    current.isRunning
                {
                    statusByTerminalSession[terminalSessionID] = current.ending(exitCode: nil, at: now)
                }

            case .commandStart:
                statusByTerminalSession[terminalSessionID] = LastCommandStatus.started(
                    commandLine: commandLine,
                    at: now
                )

            case .commandEnd(let exitCode):
                if let current = statusByTerminalSession[terminalSessionID], current.isRunning {
                    statusByTerminalSession[terminalSessionID] = current.ending(exitCode: exitCode, at: now)
                } else {
                    // ;D without a preceding ;B — happens on the very first
                    // prompt of a shell, or with shells that emit only ;D.
                    // Record a zero-duration ended status so the sliver has
                    // something to show.
                    statusByTerminalSession[terminalSessionID] = LastCommandStatus(
                        commandLine: commandLine,
                        exitCode: exitCode,
                        startedAt: now,
                        endedAt: now
                    )
                }
            }
        }
    }

    /// Drop tracking for a session — called from the host terminal session
    /// store when a session is removed.
    public func clear(terminalSessionID: UUID) {
        statusByTerminalSession.removeValue(forKey: terminalSessionID)
    }

    public func reset() {
        statusByTerminalSession = [:]
    }
}
