//
//  WorkspaceTerminalTeardownControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Exercises the forced-teardown state machine behind operator archive-with-teardown (#1226):
//  tmux dies before the close so the runtime's process-alive confirmation never fires, the
//  blocked arm returns the typed close_blocked_by_confirmation outcome instead of retiring under
//  a prompt, and the completed report says exactly what died. Gate evidence for the dialog arm:
//  https://evidence.cloudcompute.com/workspaces/pr-1246/20260808-000422-main-gate-tmux-close-dialog.png
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("WorkspaceTerminalTeardownController")
struct WorkspaceTerminalTeardownControllerTests {
    private static let scope = HostTerminalSessionKey.hostPath("/tmp/ws")

    private func session(
        directory: String = "/tmp/ws",
        tmuxOverride: String? = nil
    ) -> HostTerminalSession {
        HostTerminalSession(
            key: Self.scope,
            directory: URL(fileURLWithPath: directory),
            tmuxSessionNameOverride: tmuxOverride
        )
    }

    /// A tmux-mode terminal with a live client process (not just an idle shell): its close raises
    /// the confirmation until its tmux session is killed. Teardown must complete without a dialog
    /// ever blocking it — the tmux kill happens first, which is what frees the close.
    @Test("tmux-mode live client: kill precedes close, teardown completes without the dialog")
    func tmuxKillPrecedesClose() async {
        let primary = session()
        let pane = session(tmuxOverride: "wm-ws-deadbeef-p12345678")
        let tmuxNames = [primary.effectiveTmuxSessionName, pane.effectiveTmuxSessionName]

        // Shared mutable state modeling the tmux server: sessions alive until killed. The close
        // hook consults it, so closing before the kill would raise the confirmation arm.
        final class TmuxServer {
            var live: Set<String>
            init(_ names: [String]) { live = Set(names) }
        }
        let server = TmuxServer(tmuxNames)
        var killOrder: [String] = []
        var closedSessions: [UUID] = []
        var retiredScopes: [HostTerminalSessionKey] = []

        let sessionsByID = [primary.id: primary, pane.id: pane]
        let controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [pane, primary] },
            tmuxSessionName: { $0.effectiveTmuxSessionName },
            killTmuxSession: { name in
                killOrder.append(name)
                return server.live.remove(name) != nil
            },
            closeForRetirement: { sessionID in
                let name = sessionsByID[sessionID]?.effectiveTmuxSessionName ?? ""
                if server.live.contains(name) {
                    // The tmux client still runs: the runtime would prompt.
                    throw GhosttySurfaceRetirementCloseError.processStillRunning(title: name)
                }
                closedSessions.append(sessionID)
            },
            retireSessions: { key in
                retiredScopes.append(key)
                return [pane.id, primary.id]
            }
        )

        let outcome = await controller.teardown(scopeKey: Self.scope)

        #expect(Set(killOrder) == Set(tmuxNames))
        #expect(closedSessions == [pane.id, primary.id])
        #expect(retiredScopes == [Self.scope])
        #expect(
            outcome
                == .completed(
                    AutomationWorkspaceArchiveTeardownReport(
                        retiredSurfaceIDs: [pane.id.uuidString, primary.id.uuidString],
                        killedTmuxSessions: [pane.effectiveTmuxSessionName, primary.effectiveTmuxSessionName]
                    )))
    }

    /// The race observed in the live #1226 loop: the tmux kill succeeds but the client's exit is
    /// asynchronous, so the first close attempts still see a running process. A killed session
    /// retries within the budget instead of declaring the blocked arm.
    @Test("a killed session whose client is still exiting retries the close until it lands")
    func killedSessionRetriesUntilClientExits() async {
        let racing = session()
        var closeAttempts = 0
        var controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [racing] },
            tmuxSessionName: { $0.effectiveTmuxSessionName },
            killTmuxSession: { _ in true },
            closeForRetirement: { _ in
                closeAttempts += 1
                if closeAttempts < 4 {
                    throw GhosttySurfaceRetirementCloseError.processStillRunning(title: "ws")
                }
            },
            retireSessions: { _ in [racing.id] }
        )
        // The budget is effectively unbounded so the loop terminates on the fake's success, never
        // the clock — under parallel suite load a tuned real-time budget loses the race (observed:
        // 10ms sleeps stretching past a 2s budget). The budget-lapse arm has its own test below.
        controller.killedProcessExitBudget = .seconds(3600)
        controller.closeRetryInterval = .milliseconds(1)

        let outcome = await controller.teardown(scopeKey: Self.scope)

        #expect(closeAttempts == 4)
        #expect(
            outcome
                == .completed(
                    AutomationWorkspaceArchiveTeardownReport(
                        retiredSurfaceIDs: [racing.id.uuidString],
                        killedTmuxSessions: [racing.effectiveTmuxSessionName]
                    )))
    }

    @Test("a killed session that never stops running blocks typed once the budget lapses")
    func killedSessionExhaustsBudgetThenBlocks() async {
        let stuck = session()
        var retired = false
        var controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [stuck] },
            tmuxSessionName: { $0.effectiveTmuxSessionName },
            killTmuxSession: { _ in true },
            closeForRetirement: { _ in
                throw GhosttySurfaceRetirementCloseError.processStillRunning(title: "ws")
            },
            retireSessions: { _ in
                retired = true
                return [stuck.id]
            }
        )
        controller.killedProcessExitBudget = .milliseconds(100)
        controller.closeRetryInterval = .milliseconds(10)

        let outcome = await controller.teardown(scopeKey: Self.scope)

        guard case .closeBlockedByConfirmation = outcome else {
            Issue.record("expected close_blocked_by_confirmation, got \(outcome)")
            return
        }
        #expect(!retired)
    }

    @Test("a process the tmux kill cannot end returns the typed blocked outcome and retires nothing")
    func blockedCloseFailsTyped() async {
        let live = session()
        var retired = false
        let controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [live] },
            tmuxSessionName: { _ in nil },
            killTmuxSession: { _ in false },
            closeForRetirement: { _ in
                throw GhosttySurfaceRetirementCloseError.processStillRunning(title: "ws")
            },
            retireSessions: { _ in
                retired = true
                return [live.id]
            }
        )

        let outcome = await controller.teardown(scopeKey: Self.scope)

        guard case .closeBlockedByConfirmation(let message) = outcome else {
            Issue.record("expected close_blocked_by_confirmation, got \(outcome)")
            return
        }
        #expect(message.contains("close confirmation"))
        #expect(!retired)
    }

    @Test("a close timeout does not block teardown; retirement still reclaims the surface")
    func timeoutProceedsToRetirement() async {
        let slow = session()
        let controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [slow] },
            tmuxSessionName: { _ in nil },
            killTmuxSession: { _ in false },
            closeForRetirement: { _ in
                throw GhosttySurfaceRetirementCloseError.timedOut(title: "ws")
            },
            retireSessions: { _ in [slow.id] }
        )

        let outcome = await controller.teardown(scopeKey: Self.scope)

        #expect(
            outcome
                == .completed(
                    AutomationWorkspaceArchiveTeardownReport(
                        retiredSurfaceIDs: [slow.id.uuidString],
                        killedTmuxSessions: []
                    )))
    }

    @Test("non-tmux idle scope closes gracefully with no tmux kills")
    func nonTmuxIdleScope() async {
        let idle = session()
        var killCalls = 0
        var closed: [UUID] = []
        let controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [idle] },
            tmuxSessionName: { _ in nil },
            killTmuxSession: { _ in
                killCalls += 1
                return true
            },
            closeForRetirement: { closed.append($0) },
            retireSessions: { _ in [idle.id] }
        )

        let outcome = await controller.teardown(scopeKey: Self.scope)

        #expect(killCalls == 0)
        #expect(closed == [idle.id])
        #expect(
            outcome
                == .completed(
                    AutomationWorkspaceArchiveTeardownReport(
                        retiredSurfaceIDs: [idle.id.uuidString],
                        killedTmuxSessions: []
                    )))
    }

    @Test("sessions sharing one tmux name kill it once; a failed kill is not reported killed")
    func killDedupAndFailedKillOmitted() async {
        let a = session()
        let b = session()  // same directory → same derived tmux name
        let stubborn = session(tmuxOverride: "wm-stuck-p1")
        var killCalls: [String] = []
        let controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [a, b, stubborn] },
            tmuxSessionName: { $0.effectiveTmuxSessionName },
            killTmuxSession: { name in
                killCalls.append(name)
                return name != "wm-stuck-p1"
            },
            closeForRetirement: { _ in },
            retireSessions: { _ in [a.id, b.id, stubborn.id] }
        )

        let outcome = await controller.teardown(scopeKey: Self.scope)

        #expect(killCalls == [a.effectiveTmuxSessionName, "wm-stuck-p1"])
        guard case .completed(let report) = outcome else {
            Issue.record("expected completed, got \(outcome)")
            return
        }
        #expect(report.killedTmuxSessions == [a.effectiveTmuxSessionName])
    }

    /// The kill-list derivation the live wiring uses. A remote (`customCommand`) surface launches
    /// its command directly and never under tmux, so its directory derivation names a session it
    /// does not own — killing it would take down whatever local surface holds that name.
    @Test("kill-list derivation excludes remote sessions and every session outside tmux mode")
    func killListDerivationExcludesRemoteSessions() async {
        let local = session()
        let remote = HostTerminalSession(
            key: Self.scope,
            directory: URL(fileURLWithPath: "/tmp/ws"),
            customCommand: "ssh sandbox"
        )
        #expect(local.effectiveTmuxSessionName == remote.effectiveTmuxSessionName)

        #expect(
            WorkspaceTerminalTeardownController.tmuxSessionNameForTeardown(of: local, mode: .tmuxPerSession)
                == local.effectiveTmuxSessionName)
        #expect(
            WorkspaceTerminalTeardownController.tmuxSessionNameForTeardown(of: remote, mode: .tmuxPerSession) == nil)
        #expect(
            WorkspaceTerminalTeardownController.tmuxSessionNameForTeardown(of: local, mode: .ghosttyManagedSplits)
                == nil)

        // Through the state machine on the real derivation: the remote session still closes and
        // retires, it just contributes no name to the kill list.
        var killCalls: [String] = []
        var closed: [UUID] = []
        let controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [remote] },
            tmuxSessionName: {
                WorkspaceTerminalTeardownController.tmuxSessionNameForTeardown(of: $0, mode: .tmuxPerSession)
            },
            killTmuxSession: { name in
                killCalls.append(name)
                return true
            },
            closeForRetirement: { closed.append($0) },
            retireSessions: { _ in [remote.id] }
        )

        let outcome = await controller.teardown(scopeKey: Self.scope)

        #expect(killCalls.isEmpty)
        #expect(closed == [remote.id])
        #expect(
            outcome
                == .completed(
                    AutomationWorkspaceArchiveTeardownReport(
                        retiredSurfaceIDs: [remote.id.uuidString],
                        killedTmuxSessions: []
                    )))
    }
}
