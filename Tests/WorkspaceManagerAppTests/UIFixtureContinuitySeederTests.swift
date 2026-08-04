//
//  UIFixtureContinuitySeederTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the restore-banner continuity seeder (issue #1192): the request
//  gate, the seed plan's shape, and an end-to-end proof that the row it writes
//  clears every suppression predicate in MainWindowRestoreController.disposition.
//

import Foundation
import SwiftData
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

    // MARK: - Production-database safety gate

    /// Codex review (#1192): `isRequested` alone doesn't prove the resolved database is an
    /// isolated fixture one — an explicit `WORKSPACES_DATA_DIR`/`WORKSPACES_LOCAL_STATE_DIR`
    /// override could, by accident or inherited shell config, resolve to the same path a real,
    /// unconfigured launch would use. `isSafeToSeed` is the independent check that refuses that
    /// case regardless of which override produced it.
    @Test("Refuses to seed the real, unconfigured production database path")
    func refusesTheProductionDatabasePath() throws {
        let productionDatabaseURL = try LocalStateStoreBootstrapper.defaultDatabaseURL(launchEnvironment: [:])
        #expect(!UIFixtureContinuitySeeder.isSafeToSeed(databaseURL: productionDatabaseURL))
    }

    @Test("Allows seeding an isolated fixture database path")
    func allowsAnIsolatedDatabasePath() {
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIFixtureContinuitySeederTests-isolated-\(UUID().uuidString)")
            .appendingPathComponent("local-state.sqlite")
        #expect(UIFixtureContinuitySeeder.isSafeToSeed(databaseURL: isolated))
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

    /// The acceptance test for #1192: seed through the same write path the app uses, resolve it
    /// against the *real* fixture-seeded SwiftData (`UIFixtureSeeder.seedDataIfNeeded` into an
    /// in-memory `ModelContainer`, the same call `WorkspaceManagerApp.init()` makes) via the
    /// *real* `RestoreTargetIndexBuilder` and path normalization — not a hand-built index — and
    /// confirm `MainWindowRestoreController` offers the result. If this passes, the
    /// evidence-lane capture is a rendering formality, not an open question about whether real
    /// path construction and normalization actually agree on both sides.
    @Test("The seeded row reaches .offer through the real restore-planning path")
    @MainActor
    func seededRowReachesOffer() async throws {
        let db = try makeDatabaseURL()
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let priorRunNow = Date(timeIntervalSince1970: 1_700_000_600)
        let currentRunStartedAt = Date(timeIntervalSince1970: 1_700_100_000)

        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        UIFixtureSeeder.seedDataIfNeeded(in: context)
        let repos = try context.fetch(FetchDescriptor<Repo>())

        try await UIFixtureContinuitySeeder.seed(databaseURL: db, homeDirectory: homeDirectory, now: priorRunNow)

        let coordinator = TerminalRestoreCoordinator(
            localStateStore: try LocalStateStore(databaseURL: db, runID: UUID(), runStartedAt: currentRunStartedAt),
            tmuxProbe: TmuxSessionProbe(run: { _, _, _ in nil }, environment: [:]),
            transcriptResumability: ClaudeTranscriptResumability(environment: [:], fileExists: { _ in false })
        )
        let index = RestoreTargetIndexBuilder(
            homeDirectoryPath: homeDirectory.path,
            normalizePath: RestorePathNormalization.normalize
        ).build(repos: repos)

        let plan = await coordinator.makePlan(index: index)
        let seededDirectory = UIFixtureContinuitySeeder.seededWorkspaceDirectory(homeDirectory: homeDirectory)
        let surface = try #require(plan.surfaces.first)
        #expect(plan.surfaces.count == 1)
        #expect(surface.key == .hostPath(seededDirectory.path))
        #expect(surface.action == .freshShell)

        let disposition = MainWindowRestoreController().disposition(
            for: plan,
            handledRunID: "",
            seedKey: .defaultHome,
            seedDirectory: homeDirectory
        )
        #expect(disposition == .offer)
    }

    // MARK: - App-wiring plumbing: env vars in, a readable row out

    /// Exercises `seedIfNeeded`/`waitUntilSeeded` themselves — the static-Task glue
    /// `WorkspaceManagerApp.init()` and `ContentView.computeRestorePlanIfEnabled()` actually
    /// call — rather than the pure `seed(databaseURL:)` function the other tests drive directly.
    @Test("seedIfNeeded resolves WORKSPACES_DATA_DIR and waitUntilSeeded blocks until the write lands")
    @MainActor
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
