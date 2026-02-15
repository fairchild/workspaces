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
}
