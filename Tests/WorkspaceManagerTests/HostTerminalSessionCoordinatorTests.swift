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
}
