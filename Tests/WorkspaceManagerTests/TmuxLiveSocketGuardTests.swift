//
//  TmuxLiveSocketGuardTests.swift
//  WorkspaceManagerTests
//
//  The guard that keeps a test process off the running app's tmux socket. Refusals are
//  observed through the guard's task-local hook, so a refused call neither runs nor
//  fails the process.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TmuxLiveSocketGuard")
struct TmuxLiveSocketGuardTests {
    /// Every refusal the guard reported while a test observed it.
    private final class Refusals: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func append(_ message: String) {
            lock.withLock { messages.append(message) }
        }

        var count: Int {
            lock.withLock { messages.count }
        }
    }

    private static var probeSocketIsLive: Bool {
        TmuxLiveSocketGuard.liveSocketLabels.contains(TmuxSessionProbe.socketLabel)
    }

    @Test("This test process knows it is one, so a surface it realizes is checked")
    func recognizesTheTestProcess() {
        #expect(TmuxLiveSocketGuard.isTestProcess)
    }

    @Test("A test may not reach tmux on a live socket; the app and isolated labels may")
    func refusesOnlyLiveLabelsInTests() {
        #expect(TmuxLiveSocketGuard.refusal(socketLabel: "workspaces", inTestProcess: true) != nil)
        #expect(TmuxLiveSocketGuard.refusal(socketLabel: "workspaces-rejected-label", inTestProcess: true) != nil)
        #expect(TmuxLiveSocketGuard.refusal(socketLabel: "wstest-1a2b3c4d", inTestProcess: true) == nil)
        #expect(TmuxLiveSocketGuard.refusal(socketLabel: "workspaces", inTestProcess: false) == nil)
        #expect(TmuxLiveSocketGuard.permits(tmuxArguments: ["tmux", "-V"]))
        #expect(TmuxLiveSocketGuard.permits(tmuxArguments: ["tmux", "-L", "wstest-1a2b3c4d", "ls"]))
    }

    @Test(
        "A session question from a test never reaches the live socket",
        .enabled(if: probeSocketIsLive, "the probe socket is overridden to an isolated label")
    )
    func sessionQuestionIsRefused() async {
        let refusals = Refusals()
        await TmuxLiveSocketGuard.$onRefusal.withValue({ refusals.append($0) }) {
            #expect(await TmuxSessionProbe().isSessionAlive("wstest-never-named") == false)
        }
        #expect(refusals.count == 1)
    }

    @Test(
        "A kill from a test never reaches the live socket",
        .enabled(if: probeSocketIsLive, "the probe socket is overridden to an isolated label")
    )
    func killIsRefused() async {
        let refusals = Refusals()
        await TmuxLiveSocketGuard.$onRefusal.withValue({ refusals.append($0) }) {
            #expect(await TmuxSessionProbe().killSession(id: "$999999") == false)
        }
        #expect(refusals.count == 1)
    }

    @Test("The holder and exit-empty questions from a test never reach the live socket")
    func holderQuestionsAreRefused() async {
        let refusals = Refusals()
        await TmuxLiveSocketGuard.$onRefusal.withValue({ refusals.append($0) }) {
            let holder = TmuxHolderProbe(socketLabel: TmuxSessionProbe.defaultSocketLabel)
            #expect(await holder.holderState(for: .init(name: "wstest-never-named")) == .unanswered)
            #expect(await TmuxExitEmptyCapability.readFromServer(TmuxSessionProbe.defaultSocketLabel) == nil)
            #expect(await holder.serverPID(attachingClientInGroup: 1, toSessionNamed: "wstest-never-named") == nil)
        }
        #expect(refusals.count == 3)
    }

    @Test("A session control question from a test never reaches the live socket")
    func sessionControlIsRefused() async {
        let refusals = Refusals()
        await TmuxLiveSocketGuard.$onRefusal.withValue({ refusals.append($0) }) {
            let control = TmuxSessionControl(socketLabel: TmuxSessionControl.defaultSocketLabel)
            #expect(await control.isLive(handle: "wstest-never-named") == false)
        }
        #expect(refusals.count == 1)
    }
}
