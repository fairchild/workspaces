import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("TerminalRestoreCoordinator")
struct TerminalRestoreCoordinatorTests {
    /// End-to-end over a real (temporary) LocalStateStore: seed an active
    /// tmux-backed session, then assert the coordinator reads it, bridges the
    /// async tmux probe to the planner, resolves the target, and plans a reattach.
    @Test("Plans a tmux reattach for a live, resolvable session")
    func plansReattachForLiveSession() async throws {
        let directory = URL(fileURLWithPath: "/code/app")
        let store = try makeStore()
        try await store.recordTerminalSession(
            HostTerminalSession(id: UUID(), key: .repoPath(directory.path), directory: directory),
            terminalMode: "tmux_per_session",
            isActive: true,
            hooksSocketPath: nil
        )

        let coordinator = TerminalRestoreCoordinator(
            localStateStore: store,
            tmuxProbe: TmuxSessionProbe(run: { _, _, _ in 0 }, environment: [:]),  // every session "alive"
            transcriptResumability: ClaudeTranscriptResumability(environment: [:], fileExists: { _ in false }),
            normalizePath: { $0 }
        )
        let index = RestoreTargetIndex(
            homeDirectoryPath: "/Users/me",
            repos: [RestoreTargetIndex.Entry(normalizedPath: directory.path, rootPath: directory.path)],
            workspaces: []
        )

        let plan = await coordinator.makePlan(index: index)
        let surface = try #require(plan.surfaces.first)
        #expect(plan.surfaces.count == 1)
        if case .reattachTmux = surface.action {
        } else {
            Issue.record("expected reattachTmux, got \(surface.action)")
        }
    }

    @Test("Plans nothing when the session's target no longer resolves")
    func dropsUnresolvableSession() async throws {
        let directory = URL(fileURLWithPath: "/code/gone")
        let store = try makeStore()
        try await store.recordTerminalSession(
            HostTerminalSession(id: UUID(), key: .repoPath(directory.path), directory: directory),
            terminalMode: "tmux_per_session",
            isActive: true,
            hooksSocketPath: nil
        )

        let coordinator = TerminalRestoreCoordinator(
            localStateStore: store,
            tmuxProbe: TmuxSessionProbe(run: { _, _, _ in 0 }, environment: [:]),
            transcriptResumability: ClaudeTranscriptResumability(environment: [:], fileExists: { _ in false }),
            normalizePath: { $0 }
        )
        // Empty index → the repo target does not resolve.
        let index = RestoreTargetIndex(homeDirectoryPath: "/Users/me", repos: [], workspaces: [])

        let plan = await coordinator.makePlan(index: index)
        #expect(plan.surfaces.isEmpty)
    }

    private func makeStore() throws -> LocalStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalRestoreCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LocalStateStore(databaseURL: directory.appendingPathComponent("state.sqlite"))
    }
}
