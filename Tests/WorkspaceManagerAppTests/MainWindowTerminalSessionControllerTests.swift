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
        let store = HostTerminalStateStore()
        let defaultDirectory = URL(fileURLWithPath: "/Users/test")

        let result = try #require(
            controller.createTabFromCurrentContext(
                hostTerminalState: store,
                defaultHomeDirectory: defaultDirectory,
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
        #expect(result.focusSessionID == store.activeSessionID)
    }

    @Test("Selecting adjacent tab returns focus target and synced workspace")
    func selectingAdjacentTabReturnsFocusAndWorkspace() throws {
        let fixture = makeRepoWorkspaceFixture()
        let store = HostTerminalStateStore()
        _ = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        )
        let workspaceSession = store.activateSession(
            key: .hostPath(fixture.workspace.path),
            directory: fixture.workspace.workspaceURL
        ).session

        let result = try #require(
            controller.selectAdjacentTab(
                offset: -1,
                hostTerminalState: store,
                repos: [fixture.repo],
                normalizePath: normalizePath
            )
        )

        #expect(result.focusSessionID != workspaceSession.id)
        #expect(result.syncedWorkspace == nil)

        let workspaceResult = try #require(
            controller.selectTab(
                sessionID: workspaceSession.id,
                hostTerminalState: store,
                repos: [fixture.repo],
                normalizePath: normalizePath
            )
        )
        #expect(workspaceResult.focusSessionID == workspaceSession.id)
        #expect(workspaceResult.syncedWorkspace?.id == fixture.workspace.id)
    }

    @Test("Force close removes session and resolves fallback focus")
    func forceCloseResolvesFallbackFocus() throws {
        let store = HostTerminalStateStore()
        let first = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let second = try #require(store.createTab())

        let result = try #require(
            controller.forceCloseTab(
                sessionID: second.id,
                hostTerminalState: store,
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
        let store = HostTerminalStateStore()
        let session = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        var requestedCloseIDs: [UUID] = []

        let results = controller.closeTabs(
            [session.id],
            hostTerminalState: store,
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

    @Test("Close confirmation uses tab title override")
    func closeConfirmationUsesTabTitleOverride() throws {
        let store = HostTerminalStateStore()
        let session = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        #expect(store.setTabTitle("Build", for: session.id))

        let confirmation = controller.closeConfirmation(
            sessionID: session.id,
            hostTerminalState: store
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
