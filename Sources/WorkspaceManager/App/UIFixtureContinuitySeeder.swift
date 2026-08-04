//
//  UIFixtureContinuitySeeder.swift
//  WorkspaceManager
//
//  Seeds a synthetic "previous run" continuity row so fixture-mode launches can
//  stage the cold-start restore banner (issue #1192). The evidence lane always
//  launches with --clean-data, which wipes LocalStateStore's SQLite continuity
//  rows before every capture — the same wipe that makes captures deterministic
//  also makes the restore banner impossible to stage, since it depends on rows
//  written by a run that already ended. This writes through a second
//  LocalStateStore instance stamped with an earlier runStartedAt, so the real
//  app's own store reads it back as a genuine prior run — the identical
//  production path TerminalRestoreCoordinator drives at real cold start.
//

import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "UIFixtureContinuitySeeder")

enum UIFixtureContinuitySeeder {
    static let seedRestoreBannerEnvKey = "WORKSPACES_UI_FIXTURE_SEED_RESTORE_BANNER"

    /// How far before "now" the synthetic previous run is stamped. Only needs to be
    /// strictly earlier than the real store's own runStartedAt — the exact gap is
    /// never observed by anything that reads the row back.
    static let priorRunOffset: TimeInterval = -600

    /// The fixture workspace the synthetic session restores, relative to
    /// `~/code/workspaces/` — matches `UIFixtureSeeder`'s `feature-auth` workspace so
    /// the resolved target exists in the same launch's seeded SwiftData.
    static let seededWorkspaceRelativePath = "bertram-chat/feature-auth"

    /// `seedIfNeeded()` (called once, synchronously, from `WorkspaceManagerApp.init()`) is the
    /// only writer; `waitUntilSeeded()` (called from SwiftUI view lifecycle, necessarily after
    /// `init()` has returned) is the only reader. `nonisolated(unsafe)` documents that
    /// happens-before ordering rather than papering over an actual race — the compiler can't
    /// see across the app-init → view-lifecycle boundary that guarantees it.
    private nonisolated(unsafe) static var pendingSeed: Task<Void, Never>?

    static func isRequested(in environment: [String: String]) -> Bool {
        environment["WORKSPACES_UI_FIXTURE"] == "1" && environment[seedRestoreBannerEnvKey] == "1"
    }

    /// The directory a seeded session restores, given the home directory it resolves under.
    static func seededWorkspaceDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("code", isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(seededWorkspaceRelativePath, isDirectory: true)
    }

    /// The session to write and the runStartedAt to stamp it with, given `now`. Pure —
    /// no I/O — so the shape of what gets seeded is assertable without a database.
    static func seedPlan(homeDirectory: URL, now: Date) -> (session: HostTerminalSession, runStartedAt: Date) {
        let directory = seededWorkspaceDirectory(homeDirectory: homeDirectory)
        let session = HostTerminalSession(key: .hostPath(directory.path), directory: directory)
        return (session, now.addingTimeInterval(priorRunOffset))
    }

    /// Writes the synthetic previous-run row through a dedicated `LocalStateStore`
    /// instance on `databaseURL`. Safe to call even when the real app's own store is
    /// already open on the same file — both are separate GRDB connections in WAL mode.
    static func seed(
        databaseURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) async throws {
        let plan = seedPlan(homeDirectory: homeDirectory, now: now)
        let store = try LocalStateStore(databaseURL: databaseURL, runID: UUID(), runStartedAt: plan.runStartedAt)
        try await store.recordTerminalSession(
            plan.session,
            terminalMode: "shell",
            isActive: true,
            hooksSocketPath: nil
        )
    }

    /// Fire hook: called from `WorkspaceManagerApp.init()`. No-op unless both
    /// `WORKSPACES_UI_FIXTURE` and `seedRestoreBannerEnvKey` are `1`. The write races
    /// the rest of app startup; `waitUntilSeeded()` is the synchronization point restore
    /// planning awaits before reading, so the race never surfaces as a flaky capture.
    static func seedIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) {
        guard isRequested(in: environment) else { return }
        guard let databaseURL = try? LocalStateStoreBootstrapper.defaultDatabaseURL(launchEnvironment: environment)
        else {
            log.error("[UIFixtureContinuitySeeder] no resolvable data directory — skipping restore-banner seed")
            return
        }
        pendingSeed = Task.detached(priority: .utility) {
            do {
                try await seed(databaseURL: databaseURL, now: now)
                log.info("[UIFixtureContinuitySeeder] seeded a restorable previous-run session")
            } catch {
                log.error(
                    "[UIFixtureContinuitySeeder] failed to seed restore-banner continuity: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Awaited by `ContentView.computeRestorePlanIfEnabled()` before it reads continuity
    /// data, so restore planning never races the seed write above. A no-op — returns
    /// immediately — when no seed was requested for this launch.
    static func waitUntilSeeded() async {
        await pendingSeed?.value
    }
}
