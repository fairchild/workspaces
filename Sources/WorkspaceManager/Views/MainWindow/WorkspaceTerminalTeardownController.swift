//
//  WorkspaceTerminalTeardownController.swift
//  WorkspaceManager
//
//  Forced terminal teardown for operator archive-with-teardown (#1226). Kills the scope's tmux
//  sessions first — in tmux mode the client counts as a live process, so a plain close raises the
//  headlessly-unanswerable Ghostty confirmation — then drives the graceful retirement close and
//  retires the tile-tree rows. Injected closures keep the state machine unit-testable.
//

import Foundation
import WorkspaceManagerCore

@MainActor
struct WorkspaceTerminalTeardownController {
    enum Outcome: Equatable {
        /// Every session in scope closed without a confirmation prompt; the report says what died.
        case completed(AutomationWorkspaceArchiveTeardownReport)
        /// At least one surface still has a live process the runtime would prompt about, and the
        /// tmux-kill route could not end it. Tile-tree rows are left in place (tmux kills already
        /// issued are not undone); the caller gets the typed `close_blocked_by_confirmation` arm
        /// instead of a hang or a silent survivor.
        case closeBlockedByConfirmation(message: String)
    }

    /// All terminal sessions in the scope, split panes before their primary (close order).
    let sessionsInScope: @MainActor (HostTerminalSessionKey) -> [HostTerminalSession]
    /// The tmux session name backing a session, or `nil` when none does (non-tmux mode).
    let tmuxSessionName: @MainActor (HostTerminalSession) -> String?
    /// Kill a tmux session by name; `false` when the kill failed or the session was already gone.
    let killTmuxSession: (String) async -> Bool
    /// The graceful retirement close for one session (`GhosttySurfaceRetirementCloser` semantics).
    let closeForRetirement: @MainActor (UUID) async throws -> Void
    /// Remove the scope's rows from the tile tree, returning the retired session ids.
    let retireSessions: @MainActor (HostTerminalSessionKey) -> [UUID]
    /// How long a close whose tmux session was just killed may keep reporting a live process
    /// before the blocked arm is declared. A killed tmux session ends its client asynchronously,
    /// so a close requested inside that window still sees the process and fires the confirmation
    /// hook — expected-transient, observed live in the #1226 loop, not the dialog arm.
    var killedProcessExitBudget: Duration = .seconds(5)
    var closeRetryInterval: Duration = .milliseconds(100)

    /// The tmux session backing `session` under teardown, or `nil` when none does: outside
    /// `.tmuxPerSession` nothing launches under tmux, and a remote (`customCommand`) surface runs
    /// its command directly even in tmux mode (`TerminalSessionLaunchContext.hostSession` passes it
    /// no tmux name), so its directory derivation would name a session it does not own.
    static func tmuxSessionNameForTeardown(
        of session: HostTerminalSession,
        mode: TerminalMultiplexingMode
    ) -> String? {
        guard mode == .tmuxPerSession, !session.isRemote else { return nil }
        return session.effectiveTmuxSessionName
    }

    func teardown(scopeKey: HostTerminalSessionKey) async -> Outcome {
        let sessions = sessionsInScope(scopeKey)

        // tmux dies first: killing the session ends the client process inside each surface, which
        // is what lets the close below complete without the runtime's process-alive confirmation.
        // Order-preserving dedup keeps the report deterministic.
        var killed: [String] = []
        var seen = Set<String>()
        for session in sessions {
            guard let name = tmuxSessionName(session), seen.insert(name).inserted else { continue }
            if await killTmuxSession(name) {
                killed.append(name)
            }
        }
        let killedNames = Set(killed)

        // Graceful close per session. `timedOut` proceeds — retirement below reclaims the surface —
        // but `processStillRunning` means the close-confirmation hook fired. For a session whose
        // tmux was just killed that is the client's asynchronous exit racing the close, so retry
        // within the budget; anywhere else it is a process the kill could not end — the dialog
        // arm. Fail typed instead of tearing down under the prompt.
        var blockedNames: [String] = []
        for session in sessions {
            let tmuxWasKilled = tmuxSessionName(session).map(killedNames.contains) ?? false
            let deadline = ContinuousClock.now.advanced(by: killedProcessExitBudget)
            while true {
                do {
                    try await closeForRetirement(session.id)
                    break
                } catch let error as GhosttySurfaceRetirementCloseError {
                    guard case .processStillRunning = error else { break }
                    if tmuxWasKilled, ContinuousClock.now < deadline {
                        try? await Task.sleep(for: closeRetryInterval)
                        continue
                    }
                    blockedNames.append(session.directoryURL.lastPathComponent)
                    break
                } catch {
                    // Other close errors do not block teardown; retirement below still reclaims.
                    break
                }
            }
        }

        guard blockedNames.isEmpty else {
            return .closeBlockedByConfirmation(
                message:
                    "Terminal teardown was blocked by the close confirmation for: "
                    + blockedNames.joined(separator: ", ")
                    + ". A process is still running and the prompt cannot be answered headlessly."
            )
        }

        // Retire whatever the process-exit path has not already reclaimed. The report names the
        // sessions enumerated at entry: completion means every one of them is gone, whether the
        // exit-driven reclaim or this retire call removed its row.
        _ = retireSessions(scopeKey)
        return .completed(
            AutomationWorkspaceArchiveTeardownReport(
                retiredSurfaceIDs: sessions.map(\.id.uuidString),
                killedTmuxSessions: killed
            )
        )
    }
}
