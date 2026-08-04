//
//  UIFixtureContinuitySeederTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the restore-banner continuity seeder (issue #1192): the request
//  gate, the seed plan's shape, and an end-to-end proof that the row it writes
//  clears every suppression predicate in MainWindowRestoreController.disposition.
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("UIFixtureContinuitySeeder")
struct UIFixtureContinuitySeederTests {

    // MARK: - Request gate

    @Test("Requires both the fixture flag and the seed-specific flag")
    func isRequestedNeedsBothFlags() {
        #expect(
            UIFixtureContinuitySeeder.isRequested(in: [
                "WORKSPACES_UI_FIXTURE": "1",
                UIFixtureContinuitySeeder.seedRestoreBannerEnvKey: "1",
            ]))
        #expect(
            !UIFixtureContinuitySeeder.isRequested(in: [
                UIFixtureContinuitySeeder.seedRestoreBannerEnvKey: "1"
            ]))
        #expect(
            !UIFixtureContinuitySeeder.isRequested(in: [
                "WORKSPACES_UI_FIXTURE": "1"
            ]))
        #expect(!UIFixtureContinuitySeeder.isRequested(in: [:]))
    }

    // MARK: - Seed plan shape

    @Test("The seed plan targets the feature-auth fixture workspace, stamped before now")
    func seedPlanShape() {
        let home = URL(fileURLWithPath: "/Users/dev")
        let now = Date(timeIntervalSince1970: 1_700_100_000)

        let plan = UIFixtureContinuitySeeder.seedPlan(homeDirectory: home, now: now)

        #expect(plan.session.key == .hostPath("/Users/dev/code/workspaces/bertram-chat/feature-auth"))
        #expect(plan.session.directoryPath == "/Users/dev/code/workspaces/bertram-chat/feature-auth")
        #expect(plan.runStartedAt == now.addingTimeInterval(UIFixtureContinuitySeeder.priorRunOffset))
        #expect(plan.runStartedAt < now)
    }

    // MARK: - End-to-end: the seeded row clears every suppression predicate

    /// The acceptance test for #1192: seed through the same write path the app uses, read it
    /// back the same way cold-start restore does (`TerminalRestoreCoordinator` plus a
    /// `RestoreTargetIndex` describing the fixture-seeded `feature-auth` workspace), and
    /// confirm `MainWindowRestoreController` offers it. If this passes, the evidence-lane
    /// capture is a rendering formality — not an open question about whether the plan resolves.
    @Test("The seeded row reaches .offer through the real restore-planning path")
    @MainActor
    func seededRowReachesOffer() async throws {
        let db = try makeDatabaseURL()
        let home = URL(fileURLWithPath: "/Users/dev")
        let priorRunNow = Date(timeIntervalSince1970: 1_700_000_600)
        let currentRunStartedAt = Date(timeIntervalSince1970: 1_700_100_000)

        try await UIFixtureContinuitySeeder.seed(databaseURL: db, homeDirectory: home, now: priorRunNow)

        let coordinator = TerminalRestoreCoordinator(
            localStateStore: try LocalStateStore(databaseURL: db, runID: UUID(), runStartedAt: currentRunStartedAt),
            tmuxProbe: TmuxSessionProbe(run: { _, _, _ in nil }, environment: [:]),
            transcriptResumability: ClaudeTranscriptResumability(environment: [:], fileExists: { _ in false }),
            normalizePath: { $0 }
        )
        let seededDirectory = UIFixtureContinuitySeeder.seededWorkspaceDirectory(homeDirectory: home)
        let index = RestoreTargetIndex(
            homeDirectoryPath: home.path,
            repos: [],
            workspaces: [
                RestoreTargetIndex.Entry(normalizedPath: seededDirectory.path, rootPath: seededDirectory.path)
            ]
        )

        let plan = await coordinator.makePlan(index: index)
        let surface = try #require(plan.surfaces.first)
        #expect(plan.surfaces.count == 1)
        #expect(surface.key == .hostPath(seededDirectory.path))
        #expect(surface.action == .freshShell)

        let disposition = MainWindowRestoreController().disposition(
            for: plan,
            handledRunID: "",
            seedKey: .defaultHome,
            seedDirectory: home
        )
        #expect(disposition == .offer)
    }

    // MARK: - App-wiring plumbing: env vars in, a readable row out

    /// Exercises `seedIfNeeded`/`waitUntilSeeded` themselves — the static-Task glue
    /// `WorkspaceManagerApp.init()` and `ContentView.computeRestorePlanIfEnabled()` actually
    /// call — rather than the pure `seed(databaseURL:)` function the other tests drive directly.
    @Test("seedIfNeeded resolves WORKSPACES_DATA_DIR and waitUntilSeeded blocks until the write lands")
    func seedIfNeededWritesThroughTheRealDataDirResolution() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIFixtureContinuitySeederTests-appwiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let environment = [
            "WORKSPACES_UI_FIXTURE": "1",
            UIFixtureContinuitySeeder.seedRestoreBannerEnvKey: "1",
            "WORKSPACES_DATA_DIR": dataDirectory.path,
        ]
        let priorRunNow = Date(timeIntervalSince1970: 1_700_000_600)
        let currentRunStartedAt = Date(timeIntervalSince1970: 1_700_100_000)

        UIFixtureContinuitySeeder.seedIfNeeded(environment: environment, now: priorRunNow)
        await UIFixtureContinuitySeeder.waitUntilSeeded()

        let databaseURL = try LocalStateStoreBootstrapper.defaultDatabaseURL(launchEnvironment: environment)
        let store = try LocalStateStore(databaseURL: databaseURL, runID: UUID(), runStartedAt: currentRunStartedAt)
        let rows = try await store.fetchPreviousRunSessions()

        #expect(rows.count == 1)
        #expect(
            rows.first?.targetPath
                == UIFixtureContinuitySeeder.seededWorkspaceDirectory(
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ).path
        )
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIFixtureContinuitySeederTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.sqlite")
    }
}
