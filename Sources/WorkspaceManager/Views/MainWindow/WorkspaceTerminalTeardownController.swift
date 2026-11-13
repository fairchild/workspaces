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

    typealias Target = TileTreeStore.RetirementTarget

    /// All terminal sessions in the scope, split panes before their primary (close order).
    let sessionsInScope: @MainActor (HostTerminalSessionKey) -> [HostTerminalSession]
    /// What teardown acts on for each session, captured before its first await: the tile that
    /// holds it and the tmux session the ledger holds for it. A restore can bring a session
    /// back under the same id while teardown awaits, and that tile and its tmux session are
    /// not teardown's.
    var captureTarget: @MainActor (HostTerminalSession) -> Target = {
        Target(session: $0, tileID: nil, ownership: nil)
    }
    /// End the tmux session the target captured, when the app's ownership ledger authorized
    /// it. `false` when nothing died: the kill failed, the session was already gone, or the
    /// app could not attribute the session to a surface it launched and left it running
    /// (#1267). Taking the captured ownership rather than a name is what makes that question
    /// answerable — a name on the shared socket proves nothing about ownership.
    var killTmuxSession: @MainActor (Target) async -> Bool
    /// The graceful retirement close for one target (`GhosttySurfaceRetirementCloser` semantics).
    let closeForRetirement: @MainActor (Target) async throws -> Void
    /// Marks the coming exit of each session as its retirement, before the tmux kill or the
    /// close that can cause it, and returns what withdraws exactly those marks. Teardown holds
    /// them across every attempt, since a client's exit can land at any point, and withdraws
    /// them when it returns, so a tile a blocked teardown leaves in place has its later exit
    /// read for what it is.
    var beginRetirement: @MainActor ([UUID]) -> @MainActor () -> Void = { _ in {} }
    /// Remove the targets' rows from the tile tree, returning the retired session ids.
    let retireSessions: @MainActor (HostTerminalSessionKey, [Target]) -> [UUID]
    /// How long a close whose tmux session was just killed may keep reporting a live process
    /// before the blocked arm is declared. A killed tmux session ends its client asynchronously,
    /// so a close requested inside that window still sees the process and fires the confirmation
    /// hook — expected-transient, observed live in the #1226 loop, not the dialog arm.
    var killedProcessExitBudget: Duration = .seconds(5)
    var closeRetryInterval: Duration = .milliseconds(100)

    func teardown(scopeKey: HostTerminalSessionKey) async -> Outcome {
        let sessions = sessionsInScope(scopeKey)
        let targets = sessions.map(captureTarget)
        let withdrawRetirement = beginRetirement(sessions.map(\.id))
        defer { withdrawRetirement() }

        // tmux dies first: killing the session ends the client process inside each surface, which
        // is what lets the close below complete without the runtime's process-alive confirmation.
        //
        // Dedup on what actually died, not on what was considered, and the order-preserving list
        // keeps the report deterministic. Two surfaces in a scope can share a tmux name while only
        // one of them carries the ownership record that authorizes ending it, so skipping the
        // second occurrence of a name would let an unrecorded surface consume the only attempt
        // (#1267).
        var killed: [String] = []
        var killedNames = Set<String>()
        for target in targets {
            guard let name = target.session.tmuxSessionName, !killedNames.contains(name) else { continue }
            if await killTmuxSession(target) {
                killedNames.insert(name)
                killed.append(name)
            }
        }

        // Graceful close per session. `timedOut` proceeds — retirement below reclaims the surface —
        // but `processStillRunning` means the close-confirmation hook fired. For a session whose
        // tmux was just killed that is the client's asynchronous exit racing the close, so retry
        // within the budget; anywhere else it is a process the kill could not end — the dialog
        // arm. Fail typed instead of tearing down under the prompt.
        var blockedNames: [String] = []
        for target in targets {
            let session = target.session
            let tmuxWasKilled = session.tmuxSessionName.map(killedNames.contains) ?? false
            let deadline = ContinuousClock.now.advanced(by: killedProcessExitBudget)
            while true {
                do {
                    try await closeForRetirement(target)
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
        _ = retireSessions(scopeKey, targets)
        return .completed(
            AutomationWorkspaceArchiveTeardownReport(
                retiredSurfaceIDs: sessions.map(\.id.uuidString),
                killedTmuxSessions: killed
            )
        )
    }
}

extension WorkspaceTerminalTeardownController {
    /// Teardown wired to the live tile tree: scope enumeration, capture and retirement from
    /// the store, tmux kills of the captured ownership, and the graceful retirement close.
    init(tileTreeStore: TileTreeStore) {
        self.init(
            sessionsInScope: { key in
                tileTreeStore.sessions(inScope: key).flatMap { primary in
                    tileTreeStore.splitSessions(forPrimarySessionID: primary.id) + [primary]
                }
            },
            captureTarget: { tileTreeStore.retirementTarget(for: $0) },
            killTmuxSession: { target in
                await tileTreeStore.terminateTmuxSession(of: target.session.id, ownership: target.ownership).didKill
            },
            closeForRetirement: { try await tileTreeStore.closeForRetirement($0) },
            beginRetirement: { tileTreeStore.beginRetirement(of: $0) },
            retireSessions: { key, targets in tileTreeStore.retire(targets, inScope: key) }
        )
    }
}
