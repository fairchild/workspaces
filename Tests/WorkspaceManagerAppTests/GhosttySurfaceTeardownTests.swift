//
//  GhosttySurfaceTeardownTests.swift
//  WorkspaceManagerAppTests
//
//  #1369's libghostty half of orphan-free teardown: freeing a surface ends the whole
//  process chain its child started — `login`, the command, and a background job in the
//  same process group — and leaves nothing unreaped. tmux servers detach by design and
//  are the app's to end, so they are out of scope here.
//

import AppKit
import Darwin
import Foundation
import Testing

@testable import WorkspaceManager

@Suite("Ghostty surface teardown", .serialized)
@MainActor
struct GhosttySurfaceTeardownTests {
    private static let timeout: TimeInterval = 60
    private static let command = "/bin/bash --noprofile --norc -c 'sleep 600 & exec sleep 601'"

    @Test("Freeing a surface ends login, its command and the command's background job")
    func freeEndsTheChildChain() async throws {
        let harness = try BareGhosttyApp()
        defer { harness.shutdown() }
        let before = ProcessTree.descendants()

        let view = try harness.makeSurface(BareSurfaceConfig(command: Self.command))
        let chain = await Self.awaitChain(excluding: before)
        #expect(chain.map(ProcessTree.name).sorted() == ["login", "sleep", "sleep"], "chain: \(Self.describe(chain))")

        harness.free(view)
        let ended = await BareGhosttyApp.poll(timeout: Self.timeout) { chain.allSatisfy { !ProcessTree.exists($0) } }
        #expect(ended, "survivors: \(Self.describe(chain.filter(ProcessTree.exists)))")
    }

    @Test("Releasing an app surface view ends its whole child chain")
    func releasedViewEndsTheChildChain() async throws {
        BareGhosttyApp.prepareProcess()
        let before = ProcessTree.descendants()
        var view: GhosttySurfaceView? = GhosttySurfaceView(customCommand: Self.command)
        #expect(view?.surface != nil)

        let chain = await Self.awaitChain(excluding: before)
        #expect(chain.map(ProcessTree.name).sorted() == ["login", "sleep", "sleep"], "chain: \(Self.describe(chain))")

        view = nil
        let ended = await BareGhosttyApp.poll(timeout: Self.timeout) { chain.allSatisfy { !ProcessTree.exists($0) } }
        #expect(ended, "survivors: \(Self.describe(chain.filter(ProcessTree.exists)))")
    }

    /// A new `login` and its subtree, once both sleeps are up under it. Rooting the chain at
    /// its `login` keeps children other suites spawn meanwhile out of it.
    private static func awaitChain(excluding before: Set<pid_t>) async -> Set<pid_t> {
        var chain = Set<pid_t>()
        _ = await BareGhosttyApp.poll(timeout: timeout) {
            let logins = ProcessTree.descendants().subtracting(before).filter { ProcessTree.name($0) == "login" }
            for login in logins {
                let subtree = ProcessTree.descendants(of: login)
                if subtree.filter({ ProcessTree.name($0) == "sleep" }).count == 2 {
                    chain = subtree.union([login])
                    return true
                }
            }
            return false
        }
        return chain
    }

    private static func describe(_ pids: Set<pid_t>) -> String {
        pids.sorted().map { "\($0):\(ProcessTree.name($0))" }.joined(separator: " ")
    }
}
