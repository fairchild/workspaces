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
import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite("Ghostty surface teardown", .serialized)
@MainActor
struct GhosttySurfaceTeardownTests {
    private static let launches = 4.0
    private static let command = "/bin/bash --noprofile --norc -c 'sleep 600 & exec sleep 601'"

    @Test("Freeing a surface ends login, its command and the command's background job")
    func freeEndsTheChildChain() async throws {
        let harness = try BareGhosttyApp()
        defer { harness.shutdown() }
        let view = try harness.makeSurface(BareSurfaceConfig(command: Self.command))
        let chain = await Self.awaitChain(of: try #require(harness.surface(for: view)))
        #expect(chain.map(ProcessTree.name).sorted() == ["login", "sleep", "sleep"], "chain: \(Self.describe(chain))")

        harness.free(view)
        let ended = await BareGhosttyApp.poll(launches: Self.launches) { chain.allSatisfy { !ProcessTree.exists($0) } }
        #expect(ended, "survivors: \(Self.describe(chain.filter(ProcessTree.exists)))")
    }

    @Test("Releasing an app surface view ends its whole child chain")
    func releasedViewEndsTheChildChain() async throws {
        BareGhosttyApp.prepareProcess()
        var view: GhosttySurfaceView? = GhosttySurfaceView(customCommand: Self.command)
        let chain = await Self.awaitChain(of: try #require(view?.surface))
        #expect(chain.map(ProcessTree.name).sorted() == ["login", "sleep", "sleep"], "chain: \(Self.describe(chain))")

        view = nil
        let ended = await BareGhosttyApp.poll(launches: Self.launches) { chain.allSatisfy { !ProcessTree.exists($0) } }
        #expect(ended, "survivors: \(Self.describe(chain.filter(ProcessTree.exists)))")
    }

    /// The surface's foreground process group leader — `login`, which stays as the parent of
    /// the command — and its subtree, once both sleeps are up under it. Starting from the
    /// surface's own process group keeps children other suites spawn out of the chain.
    private static func awaitChain(of surface: ghostty_surface_t) async -> Set<pid_t> {
        var chain = Set<pid_t>()
        _ = await BareGhosttyApp.poll(launches: launches) {
            let leader = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
            guard leader > 0 else { return false }
            chain = ProcessTree.descendants(of: leader).union([leader])
            return chain.filter { ProcessTree.name($0) == "sleep" }.count == 2
        }
        return chain
    }

    private static func describe(_ pids: Set<pid_t>) -> String {
        pids.sorted().map { "\($0):\(ProcessTree.name($0))" }.joined(separator: " ")
    }
}
