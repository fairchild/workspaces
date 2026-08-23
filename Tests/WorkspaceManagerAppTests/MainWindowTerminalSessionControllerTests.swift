import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("MainWindowTerminalSessionController")
struct MainWindowTerminalSessionControllerTests {
    private let controller = MainWindowTerminalSessionController()

    @Test("Creating a tab first ensures a default session")
    func creatingTabEnsuresDefaultSession() throws {
        let store = TileTreeStore()
        let defaultDirectory = URL(fileURLWithPath: "/Users/test")

        let result = try #require(
            controller.createTabFromCurrentContext(
                tileTreeStore: store,
                defaultHomeDirectory: defaultDirectory,
                selectedRepoForLanding: nil,
                repos: [],
                normalizePath: normalizePath,
                activateHostSession: { key, directory, customCommand in
                    store.activateSession(
                        key: key,
                        directory: directory,
                        customCommand: customCommand
                    ).session
                }
            )
        )

        #expect(store.sessions.count == 2)
        #expect(store.sessions.first?.key == .defaultHome)
        #expect(result.focus.focusSessionID == store.activeSessionID)
    }

    @Test("Creating a tab is available before any session exists")
    func creatingTabIsAvailableBeforeAnySessionExists() {
        #expect(controller.canCreateTab(hasSessions: false))
    }

    @Test("Creating from a repo overview opens that repo's initial terminal")
    func creatingFromRepoOverviewOpensSelectedRepoTerminal() throws {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let store = TileTreeStore()
        _ = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        )

        let result = try #require(
            controller.createTabFromCurrentContext(
                tileTreeStore: store,
                defaultHomeDirectory: URL(fileURLWithPath: "/Users/test"),
                selectedRepoForLanding: repo,
                repos: [repo],
                normalizePath: normalizePath,
                activateHostSession: { key, directory, customCommand in
                    store.activateSession(
                        key: key,
                        directory: directory,
                        customCommand: customCommand
                    ).session
                }
            )
        )

        let focusedSession = try #require(store.sessions.first(where: { $0.id == result.focus.focusSessionID }))
        #expect(focusedSession.key == .repoPath(repo.localPath))
        #expect(focusedSession.directoryURL == repo.localURL)
        #expect(store.sessions(inScope: .repoPath(repo.localPath)).count == 1)
        switch result.navigationDestination {
        case .repoTerminal(let destinationRepo):
            #expect(destinationRepo.id == repo.id)
        default:
            Issue.record("Expected repository overview creation to navigate to its terminal")
        }
    }

    @Test("Creating from a repo overview adds a sibling in that repo's existing scope")
    func creatingFromRepoOverviewAddsSiblingInSelectedRepoScope() throws {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let store = TileTreeStore()
        let existingRepoSession = store.activateSession(
            key: .repoPath(repo.localPath),
            directory: repo.localURL
        ).session
        let otherSession = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session

        let result = try #require(
            controller.createTabFromCurrentContext(
                tileTreeStore: store,
                defaultHomeDirectory: URL(fileURLWithPath: "/Users/test"),
                selectedRepoForLanding: repo,
                repos: [repo],
                normalizePath: normalizePath,
                activateHostSession: { key, directory, customCommand in
                    store.activateSession(
                        key: key,
                        directory: directory,
                        customCommand: customCommand
                    ).session
                }
            )
        )

        let repoSessions = store.sessions(inScope: .repoPath(repo.localPath))
        #expect(repoSessions.count == 2)
        #expect(repoSessions.map(\.id).contains(existingRepoSession.id))
        #expect(repoSessions.map(\.id).contains(result.focus.focusSessionID))
        #expect(store.sessions(inScope: .defaultHome).map(\.id) == [otherSession.id])
    }

    @Test("Creating from an existing terminal keeps the active session context")
    func creatingFromExistingTerminalKeepsActiveContext() throws {
        let fixture = makeRepoWorkspaceFixture()
        let store = TileTreeStore()
        let existingSession = store.activateSession(
            key: .hostPath(fixture.workspace.path),
            directory: fixture.workspace.workspaceURL
        ).session

        let result = try #require(
            controller.createTabFromCurrentContext(
                tileTreeStore: store,
                defaultHomeDirectory: URL(fileURLWithPath: "/Users/test"),
                selectedRepoForLanding: nil,
                repos: [fixture.repo],
                normalizePath: normalizePath,
                activateHostSession: { key, directory, customCommand in
                    store.activateSession(
                        key: key,
                        directory: directory,
                        customCommand: customCommand
                    ).session
                }
            )
        )

        let workspaceSessions = store.sessions(inScope: .hostPath(fixture.workspace.path))
        #expect(workspaceSessions.count == 2)
        #expect(workspaceSessions.map(\.id).contains(existingSession.id))
        #expect(workspaceSessions.map(\.id).contains(result.focus.focusSessionID))
        #expect(result.focus.syncedWorkspace?.id == fixture.workspace.id)
        if case .some = result.navigationDestination {
            Issue.record("Expected existing-terminal creation to preserve the current surface")
        }
    }

    @Test("Selecting adjacent tab returns focus target and synced workspace")
    func selectingAdjacentTabReturnsFocusAndWorkspace() throws {
        let fixture = makeRepoWorkspaceFixture()
        let store = TileTreeStore()
        _ = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        )
        let firstWorkspaceSession = store.activateSession(
            key: .hostPath(fixture.workspace.path),
            directory: fixture.workspace.workspaceURL
        ).session
        let secondWorkspaceSession = try #require(store.createTab())

        let result = try #require(
            controller.selectAdjacentTab(
                offset: -1,
                tileTreeStore: store,
                repos: [fixture.repo],
                normalizePath: normalizePath
            )
        )

        #expect(result.focusSessionID == firstWorkspaceSession.id)
        #expect(result.syncedWorkspace?.id == fixture.workspace.id)

        let workspaceResult = try #require(
            controller.selectTab(
                sessionID: secondWorkspaceSession.id,
                tileTreeStore: store,
                repos: [fixture.repo],
                normalizePath: normalizePath
            )
        )
        #expect(workspaceResult.focusSessionID == secondWorkspaceSession.id)
        #expect(workspaceResult.syncedWorkspace?.id == fixture.workspace.id)
    }

    @Test("Force close removes session and resolves fallback focus")
    func forceCloseResolvesFallbackFocus() throws {
        let store = TileTreeStore()
        let first = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let second = try #require(store.createTab())

        let result = try #require(
            controller.forceCloseTab(
                sessionID: second.id,
                tileTreeStore: store,
                defaultHomeDirectory: URL(fileURLWithPath: "/Users/test"),
                repos: [],
                normalizePath: normalizePath
            )
        )

        #expect(store.sessions.map(\.id) == [first.id])
        #expect(result.focusSessionID == first.id)
    }

    @Test("Close requests defer to terminal surface when available")
    func closeRequestsDeferToTerminalSurface() {
        let store = TileTreeStore()
        let session = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        var requestedCloseIDs: [UUID] = []

        let results = controller.closeTabs(
            [session.id],
            tileTreeStore: store,
            defaultHomeDirectory: URL(fileURLWithPath: "/Users/test"),
            repos: [],
            normalizePath: normalizePath,
            requestClose: { sessionID in
                requestedCloseIDs.append(sessionID)
                return true
            }
        )

        #expect(requestedCloseIDs == [session.id])
        #expect(results.isEmpty)
        #expect(store.sessions.map(\.id) == [session.id])
    }

    @Test("Synced workspace selection supports backend session keys")
    func syncedWorkspaceSelectionSupportsBackendSessions() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "cloud-feature",
            path: URL(fileURLWithPath: Workspace.remotePathSentinel),
            sourceRepo: repo,
            backendIdentifier: "daytona",
            remoteId: "remote-123",
            sessionRoutingID: "routing-123"
        )
        repo.workspaces = [workspace]
        let session = HostTerminalSession(
            key: .backendSession(providerID: "daytona", instanceID: "routing-123"),
            directory: URL(fileURLWithPath: "/tmp")
        )

        let syncedWorkspace = controller.syncedWorkspaceSelection(
            activeHostSession: session,
            repos: [repo],
            normalizePath: normalizePath
        )

        #expect(syncedWorkspace?.id == workspace.id)
    }

    @Test("Terminal navigation destination routes workspace sessions to terminal surface")
    func terminalNavigationDestinationRoutesWorkspaceSessions() throws {
        let fixture = makeRepoWorkspaceFixture()
        let session = HostTerminalSession(
            key: .hostPath(fixture.workspace.path),
            directory: fixture.workspace.workspaceURL
        )

        let destination = try #require(
            controller.terminalNavigationDestination(
                for: session,
                repos: [fixture.repo],
                normalizePath: normalizePath
            )
        )

        switch destination {
        case .workspaceTerminal(let workspace):
            #expect(workspace.id == fixture.workspace.id)
        default:
            Issue.record("Expected workspace terminal destination")
        }
    }

    @Test("Terminal navigation destination routes repo sessions to terminal surface")
    func terminalNavigationDestinationRoutesRepoSessions() throws {
        let fixture = makeRepoWorkspaceFixture()
        let session = HostTerminalSession(
            key: .repoPath(fixture.repo.localPath),
            directory: fixture.repo.localURL
        )

        let destination = try #require(
            controller.terminalNavigationDestination(
                for: session,
                repos: [fixture.repo],
                normalizePath: normalizePath
            )
        )

        switch destination {
        case .repoTerminal(let repo):
            #expect(repo.id == fixture.repo.id)
        default:
            Issue.record("Expected repo terminal destination")
        }
    }

    @Test("Close confirmation uses tab title override")
    func closeConfirmationUsesTabTitleOverride() throws {
        let store = TileTreeStore()
        let session = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        #expect(store.setTabTitle("Build", for: session.id))

        let confirmation = controller.closeConfirmation(
            sessionID: session.id,
            tileTreeStore: store
        )

        #expect(confirmation.sessionID == session.id)
        #expect(confirmation.title == "Build")
    }

    private func makeRepoWorkspaceFixture() -> (repo: Repo, workspace: Workspace) {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]
        return (repo, workspace)
    }

    private func normalizePath(_ rawPath: String) -> String {
        URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
