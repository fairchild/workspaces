//
//  HostTerminalSessionCoordinatorTests.swift
//  WorkspaceManagerTests
//
//  Regression tests for host terminal session reuse and pruning semantics.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("HostTerminalSessionCoordinator")
struct HostTerminalSessionCoordinatorTests {
    @Test("Reuses existing session for same repo path key")
    func reusesByRepoPathKey() {
        var coordinator = HostTerminalSessionCoordinator()
        let repoURL = URL(fileURLWithPath: "/tmp/repo-a")

        let first = coordinator.activate(
            key: .repoPath(repoURL.path),
            directory: repoURL
        )
        let second = coordinator.activate(
            key: .repoPath(repoURL.path),
            directory: repoURL
        )

        #expect(first.created)
        #expect(!second.created)
        #expect(coordinator.sessions.count == 1)
        #expect(first.session.id == second.session.id)
        #expect(coordinator.activeSessionID == first.session.id)
    }

    @Test("Reuses existing session by canonical path when key differs")
    func reusesByCanonicalPath() {
        var coordinator = HostTerminalSessionCoordinator()
        let repoURL = URL(fileURLWithPath: "/tmp/repo-b")

        let first = coordinator.activate(
            key: .repoPath(repoURL.path),
            directory: repoURL
        )
        let second = coordinator.activate(
            key: .hostPath(repoURL.path),
            directory: repoURL
        )

        #expect(first.created)
        #expect(!second.created)
        #expect(coordinator.sessions.count == 1)
        #expect(first.session.id == second.session.id)
    }

    @Test("Backend sessions do not reuse host-path sessions for the same directory")
    func backendSessionsDoNotReuseHostPathSessions() {
        var coordinator = HostTerminalSessionCoordinator()
        let sharedDirectory = URL(fileURLWithPath: "/tmp/shared-workspace")

        let hostSession = coordinator.activate(
            key: .hostPath(sharedDirectory.path),
            directory: sharedDirectory
        )
        let backendSession = coordinator.activate(
            key: .backendSession(providerID: "lume", instanceID: "vm-123"),
            directory: sharedDirectory,
            customCommand: "/usr/local/bin/lume ssh vm-123"
        )
        let backendSessionReuse = coordinator.activate(
            key: .backendSession(providerID: "lume", instanceID: "vm-123"),
            directory: sharedDirectory,
            customCommand: "/usr/local/bin/lume ssh vm-123"
        )

        #expect(hostSession.created)
        #expect(backendSession.created)
        #expect(!backendSessionReuse.created)
        #expect(hostSession.session.id != backendSession.session.id)
        #expect(backendSession.session.id == backendSessionReuse.session.id)
        #expect(coordinator.sessions.count == 2)
    }

    @Test("Prunes removed repo sessions and keeps default host session")
    func prunesRemovedRepoSessions() {
        var coordinator = HostTerminalSessionCoordinator()

        let defaultSession = coordinator.activate(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        let keepRepoSession = coordinator.activate(
            key: .repoPath("/Users/test/code/repo-keep"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo-keep")
        ).session
        let removeRepoSession = coordinator.activate(
            key: .repoPath("/Users/test/code/repo-remove"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo-remove")
        ).session

        #expect(coordinator.activeSessionID == removeRepoSession.id)

        let removed = coordinator.pruneRepoSessions(
            validRepoPaths: ["/Users/test/code/repo-keep"]
        )

        #expect(removed == [removeRepoSession.id])
        #expect(coordinator.sessions.contains(where: { $0.id == defaultSession.id }))
        #expect(coordinator.sessions.contains(where: { $0.id == keepRepoSession.id }))
        #expect(!coordinator.sessions.contains(where: { $0.id == removeRepoSession.id }))
        #expect(coordinator.activeSessionID == keepRepoSession.id)
    }

    @Test("Removing a split-target session updates active session fallback")
    func removeSessionUpdatesActiveFallback() {
        var coordinator = HostTerminalSessionCoordinator()

        let firstSession = coordinator.activate(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        let secondSession = coordinator.activate(
            key: .repoPath("/Users/test/code/repo-a"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo-a")
        ).session

        #expect(coordinator.activeSessionID == secondSession.id)

        let removed = coordinator.remove(sessionID: secondSession.id)
        #expect(removed?.id == secondSession.id)
        #expect(coordinator.sessions.count == 1)
        #expect(coordinator.activeSessionID == firstSession.id)
    }

    @Test("Removing a missing session is a no-op")
    func removeMissingSessionIsNoOp() {
        var coordinator = HostTerminalSessionCoordinator()
        _ = coordinator.activate(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let initialSessions = coordinator.sessions
        let initialActiveID = coordinator.activeSessionID

        let removed = coordinator.remove(sessionID: UUID())

        #expect(removed == nil)
        #expect(coordinator.sessions == initialSessions)
        #expect(coordinator.activeSessionID == initialActiveID)
    }

    @Test("Presentation reports live repo paths and active repo")
    func presentationReportsLiveRepoState() {
        var coordinator = HostTerminalSessionCoordinator()
        _ = coordinator.activate(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let activeRepo = coordinator.activate(
            key: .repoPath("/Users/test/code/repo-a"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo-a")
        ).session
        _ = coordinator.activate(
            key: .repoPath("/Users/test/code/repo-b"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo-b")
        )
        _ = coordinator.activate(
            key: .repoPath("/Users/test/code/repo-a"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo-a")
        )

        let presentation = coordinator.presentation
        #expect(presentation.liveRepoPaths == Set(["/Users/test/code/repo-a", "/Users/test/code/repo-b"]))
        #expect(presentation.activeRepoPath == activeRepo.directoryPath)
        #expect(presentation.hasDefaultHomeSession)
        #expect(!presentation.isDefaultHomeSessionActive)
    }

    @Test("Presentation reports default home active when selected")
    func presentationReportsDefaultHomeActive() {
        var coordinator = HostTerminalSessionCoordinator()
        _ = coordinator.activate(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )

        let presentation = coordinator.presentation
        #expect(presentation.hasDefaultHomeSession)
        #expect(presentation.isDefaultHomeSessionActive)
        #expect(presentation.activeRepoPath == nil)
    }

    @Test("Rapid switching reuses sessions and restores active target")
    func rapidSwitchingReusesSessionsAndRestoresActiveTarget() {
        var coordinator = HostTerminalSessionCoordinator()

        let repoA = URL(fileURLWithPath: "/Users/test/code/repo-a")
        let repoB = URL(fileURLWithPath: "/Users/test/code/repo-b")
        let workspaceA = URL(fileURLWithPath: "/Users/test/workspaces/repo-a/feature-auth")

        let repoASession = coordinator.activate(
            key: .repoPath(repoA.path),
            directory: repoA
        ).session
        let repoBSession = coordinator.activate(
            key: .repoPath(repoB.path),
            directory: repoB
        ).session
        let workspaceSession = coordinator.activate(
            key: .hostPath(workspaceA.path),
            directory: workspaceA
        ).session

        let switches: [(HostTerminalSessionKey, URL, UUID)] = [
            (.repoPath(repoA.path), repoA, repoASession.id),
            (.repoPath(repoB.path), repoB, repoBSession.id),
            (.hostPath(workspaceA.path), workspaceA, workspaceSession.id),
            (.repoPath(repoA.path), repoA, repoASession.id),
            (.repoPath(repoB.path), repoB, repoBSession.id),
            (.hostPath(workspaceA.path), workspaceA, workspaceSession.id),
        ]

        for (key, directory, expectedID) in switches {
            let activation = coordinator.activate(key: key, directory: directory)
            #expect(activation.session.id == expectedID)
            #expect(coordinator.activeSessionID == expectedID)
        }

        #expect(coordinator.sessions.count == 3)
        #expect(coordinator.activeSessionID == workspaceSession.id)
    }

    @Test("Scope activation restores the last active tab for that scope")
    func scopeActivationRestoresLastActiveTab() throws {
        var coordinator = HostTerminalSessionCoordinator()
        let homeURL = URL(fileURLWithPath: "/Users/test/code")
        let repoURL = URL(fileURLWithPath: "/Users/test/code/repo-a")

        let home = coordinator.activate(key: .defaultHome, directory: homeURL).session
        let secondHomeTab = coordinator.createTab(from: home)
        let repo = coordinator.activate(key: .repoPath(repoURL.path), directory: repoURL).session
        let secondRepoTab = coordinator.createTab(from: repo)

        _ = coordinator.activate(key: .defaultHome, directory: homeURL)
        #expect(coordinator.activeSessionID == secondHomeTab.id)

        let restoredRepo = coordinator.activate(key: .repoPath(repoURL.path), directory: repoURL)
        #expect(!restoredRepo.created)
        #expect(restoredRepo.session.id == secondRepoTab.id)
        #expect(coordinator.activeSessionID == secondRepoTab.id)
    }

    @Test("Tab navigation stays within the active scope")
    func tabNavigationStaysWithinActiveScope() throws {
        var coordinator = HostTerminalSessionCoordinator()
        let homeURL = URL(fileURLWithPath: "/Users/test/code")
        let repoURL = URL(fileURLWithPath: "/Users/test/code/repo-a")

        let home = coordinator.activate(key: .defaultHome, directory: homeURL).session
        let secondHomeTab = coordinator.createTab(from: home)
        let repo = coordinator.activate(key: .repoPath(repoURL.path), directory: repoURL).session
        let secondRepoTab = coordinator.createTab(from: repo)

        #expect(coordinator.activateAdjacent(to: secondRepoTab.id, offset: 1)?.id == repo.id)
        #expect(coordinator.activateAdjacent(to: repo.id, offset: -1)?.id == secondRepoTab.id)
        #expect(coordinator.activateTab(atOneBasedIndex: 1)?.id == repo.id)
        #expect(coordinator.activateLastTab()?.id == secondRepoTab.id)

        _ = coordinator.activate(key: .defaultHome, directory: homeURL)
        #expect(coordinator.activateAdjacent(to: secondHomeTab.id, offset: 1)?.id == home.id)
    }

    @Test("Moving tabs reorders only the source scope")
    func movingTabsReordersOnlySourceScope() throws {
        var coordinator = HostTerminalSessionCoordinator()
        let homeURL = URL(fileURLWithPath: "/Users/test/code")
        let repoURL = URL(fileURLWithPath: "/Users/test/code/repo-a")

        let home = coordinator.activate(key: .defaultHome, directory: homeURL).session
        let secondHomeTab = coordinator.createTab(from: home)
        let repo = coordinator.activate(key: .repoPath(repoURL.path), directory: repoURL).session
        let secondRepoTab = coordinator.createTab(from: repo)

        let didMoveRepoTab = coordinator.moveTab(sessionID: secondRepoTab.id, offset: -1)
        #expect(didMoveRepoTab)
        #expect(coordinator.sessions(inScope: .repoPath(repoURL.path)).map(\.id) == [secondRepoTab.id, repo.id])
        #expect(coordinator.sessions(inScope: .defaultHome).map(\.id) == [home.id, secondHomeTab.id])
    }

    @Test("Canonical-path-equivalent selections do not duplicate sessions")
    func canonicalEquivalentSelectionsDoNotDuplicateSessions() throws {
        var coordinator = HostTerminalSessionCoordinator()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HostTerminalSessionCoordinator-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let canonicalRepo = root.appendingPathComponent("repo", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("aliases", isDirectory: true)
        let symlinkRepo = aliasDirectory.appendingPathComponent("repo-link", isDirectory: true)

        try fileManager.createDirectory(at: canonicalRepo, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlinkRepo, withDestinationURL: canonicalRepo)

        let dotDotPath =
            canonicalRepo
            .deletingLastPathComponent()
            .appendingPathComponent("repo")
            .path + "/../repo"
        let dotDotDirectory = URL(fileURLWithPath: dotDotPath)

        let first = coordinator.activate(
            key: .repoPath(canonicalRepo.path),
            directory: canonicalRepo
        )
        let second = coordinator.activate(
            key: .repoPath(symlinkRepo.path),
            directory: symlinkRepo
        )
        let third = coordinator.activate(
            key: .hostPath(dotDotDirectory.path),
            directory: dotDotDirectory
        )

        #expect(first.created)
        #expect(!second.created)
        #expect(!third.created)
        #expect(first.session.id == second.session.id)
        #expect(first.session.id == third.session.id)
        #expect(coordinator.sessions.count == 1)
    }

    @Test("Activating a fresh key sets initialCommand; reuse does not adopt a new one")
    func initialCommandOnCreateNotOnReuse() {
        var coordinator = HostTerminalSessionCoordinator()
        let directory = URL(fileURLWithPath: "/code/repo")

        let created = coordinator.activate(
            key: .repoPath(directory.path),
            directory: directory,
            initialCommand: "claude --resume sess-1"
        )
        #expect(created.created)
        #expect(created.session.initialCommand == "claude --resume sess-1")

        // Reusing the same key returns the existing session and does NOT adopt a new
        // initialCommand — which is exactly why executeRestore retires a pre-seeded
        // session on a plan's key before restoring (issue #783 #3).
        let reused = coordinator.activate(
            key: .repoPath(directory.path),
            directory: directory,
            initialCommand: "claude --resume sess-2"
        )
        #expect(!reused.created)
        #expect(reused.session.id == created.session.id)
        #expect(reused.session.initialCommand == "claude --resume sess-1")
    }
}
