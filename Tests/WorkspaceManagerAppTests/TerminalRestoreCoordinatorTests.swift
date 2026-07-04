import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("TerminalRestoreCoordinator")
struct TerminalRestoreCoordinatorTests {
    private static let priorRun = Date(timeIntervalSince1970: 1_700_000_000)
    private static let currentRun = Date(timeIntervalSince1970: 1_700_100_000)

    /// End-to-end over a real (temporary) LocalStateStore: a PRIOR run records an
    /// active tmux-backed session; the coordinator (constructed with a CURRENT-run
    /// store on the same DB) reads only the previous run, bridges the async tmux
    /// probe to the planner, resolves the target, and plans a reattach.
    @Test("Plans a tmux reattach for a live, resolvable previous-run session")
    func plansReattachForLiveSession() async throws {
        let directory = URL(fileURLWithPath: "/code/app")
        let db = try makeDatabaseURL()

        let priorRun = try makeStore(at: db, runStartedAt: Self.priorRun)
        try await priorRun.recordTerminalSession(
            HostTerminalSession(id: UUID(), key: .repoPath(directory.path), directory: directory),
            terminalMode: "tmux_per_session",
            isActive: true,
            hooksSocketPath: nil
        )

        let coordinator = TerminalRestoreCoordinator(
            localStateStore: try makeStore(at: db, runStartedAt: Self.currentRun),
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

    @Test("Plans nothing when the previous-run session's target no longer resolves")
    func dropsUnresolvableSession() async throws {
        let directory = URL(fileURLWithPath: "/code/gone")
        let db = try makeDatabaseURL()

        let priorRun = try makeStore(at: db, runStartedAt: Self.priorRun)
        try await priorRun.recordTerminalSession(
            HostTerminalSession(id: UUID(), key: .repoPath(directory.path), directory: directory),
            terminalMode: "tmux_per_session",
            isActive: true,
            hooksSocketPath: nil
        )

        let coordinator = TerminalRestoreCoordinator(
            localStateStore: try makeStore(at: db, runStartedAt: Self.currentRun),
            tmuxProbe: TmuxSessionProbe(run: { _, _, _ in 0 }, environment: [:]),
            transcriptResumability: ClaudeTranscriptResumability(environment: [:], fileExists: { _ in false }),
            normalizePath: { $0 }
        )
        // Empty index → the repo target does not resolve.
        let index = RestoreTargetIndex(homeDirectoryPath: "/Users/me", repos: [], workspaces: [])

        let plan = await coordinator.makePlan(index: index)
        #expect(plan.surfaces.isEmpty)
    }

    @Test("Plans nothing when only the current run has sessions (no previous run)")
    func plansNothingWithoutPriorRun() async throws {
        let directory = URL(fileURLWithPath: "/code/app")
        let db = try makeDatabaseURL()

        // Only the current run records a session — there is no prior run to restore.
        let current = try makeStore(at: db, runStartedAt: Self.currentRun)
        try await current.recordTerminalSession(
            HostTerminalSession(id: UUID(), key: .repoPath(directory.path), directory: directory),
            terminalMode: "tmux_per_session",
            isActive: true,
            hooksSocketPath: nil
        )

        let coordinator = TerminalRestoreCoordinator(
            localStateStore: current,
            tmuxProbe: TmuxSessionProbe(run: { _, _, _ in 0 }, environment: [:]),
            transcriptResumability: ClaudeTranscriptResumability(environment: [:], fileExists: { _ in false }),
            normalizePath: { $0 }
        )
        let index = RestoreTargetIndex(
            homeDirectoryPath: "/Users/me",
            repos: [RestoreTargetIndex.Entry(normalizedPath: directory.path, rootPath: directory.path)],
            workspaces: []
        )

        let plan = await coordinator.makePlan(index: index)
        #expect(plan.surfaces.isEmpty)
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalRestoreCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.sqlite")
    }

    private func makeStore(at databaseURL: URL, runStartedAt: Date) throws -> LocalStateStore {
        try LocalStateStore(databaseURL: databaseURL, runID: UUID(), runStartedAt: runStartedAt)
    }
}
