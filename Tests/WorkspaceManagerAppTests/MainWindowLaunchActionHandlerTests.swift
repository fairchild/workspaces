import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("MainWindowLaunchActionHandler")
struct MainWindowLaunchActionHandlerTests {
    private let handler = MainWindowLaunchActionHandler()

    @Test("Deep linked workspace action clears request selects workspace and focuses window")
    func deepLinkedWorkspaceActionAppliesSideEffects() throws {
        var state = MainWindowViewState()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        let request = try #require(makeDeepLink(cwd: "/tmp/alpha/workspaces/feature-a"))
        var clearedDeepLink = false
        var discardedReason: String?
        var selectedWorkspaceID: UUID?
        var preferredDirectory: URL?
        var didFocusWindow = false

        let shouldContinue = handler.apply(
            .selectDeepLinkedWorkspace(request, workspace),
            state: &state,
            environment: [:],
            pendingRequest: request,
            bootstrapController: MainWindowBootstrapController(),
            actions: makeActions(
                clearDeepLink: { clearedDeepLink = true },
                discardPendingRemoteConnection: { discardedReason = $0 },
                selectWorkspace: { workspace, directory in
                    selectedWorkspaceID = workspace.id
                    preferredDirectory = directory
                },
                focusWorkspaceWindow: { didFocusWindow = true }
            )
        )

        #expect(!shouldContinue)
        #expect(state.didResolveInitialSurface)
        #expect(clearedDeepLink)
        #expect(discardedReason == "deep_link_selected")
        #expect(selectedWorkspaceID == workspace.id)
        #expect(preferredDirectory?.path == request.cwd)
        #expect(didFocusWindow)
    }

    @Test("Preview bootstrap selects repo terminal and opens preview pane")
    func previewBootstrapAppliesPreviewState() throws {
        var state = MainWindowViewState()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let selection = CodePreviewSelection(
            rootURL: repo.localURL,
            relativePath: "README.md"
        )
        var selectedRepoID: UUID?

        let shouldContinue = handler.apply(
            .applyPreviewBootstrap(
                UIFixturePreviewBootstrapConfiguration(repoName: "alpha", relativePath: "README.md"),
                repo,
                selection
            ),
            state: &state,
            environment: [:],
            pendingRequest: nil,
            bootstrapController: MainWindowBootstrapController(),
            actions: makeActions(
                selectRepoTerminal: { repo, preferredDirectory in
                    selectedRepoID = repo.id
                    #expect(preferredDirectory == nil)
                }
            )
        )

        #expect(!shouldContinue)
        #expect(state.didApplyFixturePreviewBootstrap)
        #expect(state.didResolveInitialSurface)
        #expect(state.selectedCodePreview == selection)
        #expect(state.isTerminalPanelVisible)
        #expect(state.isRightPaneVisible)
        #expect(selectedRepoID == repo.id)
    }

    @Test("Invalid last surface clears before continuing")
    func invalidLastSurfaceClearsAndContinues() {
        var state = MainWindowViewState()
        var clearedLastSurface = false

        let shouldContinue = handler.apply(
            .clearInvalidLastSurface,
            state: &state,
            environment: [:],
            pendingRequest: nil,
            bootstrapController: MainWindowBootstrapController(),
            actions: makeActions(clearLastSurface: { clearedLastSurface = true })
        )

        #expect(shouldContinue)
        #expect(clearedLastSurface)
    }

    @Test("Fallback applies launch surface and marks initial resolution")
    func fallbackAppliesLaunchSurface() {
        var state = MainWindowViewState()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        var appliedRepoID: UUID?

        let shouldContinue = handler.apply(
            .fallback(.repoOverview(repo)),
            state: &state,
            environment: [:],
            pendingRequest: nil,
            bootstrapController: MainWindowBootstrapController(),
            actions: makeActions(
                applyLaunchSurface: { surface in
                    if case .repoOverview(let repo) = surface {
                        appliedRepoID = repo.id
                    }
                }
            )
        )

        #expect(!shouldContinue)
        #expect(state.didResolveInitialSurface)
        #expect(appliedRepoID == repo.id)
    }

    @Test("Perf auto-select records run state and schedules workspace sheet when enabled")
    func perfAutoSelectRecordsRunState() {
        var state = MainWindowViewState()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        var scheduledRepoID: UUID?
        var scheduledOpenNewWorkspace = false

        let shouldContinue = handler.apply(
            .perfAutoSelect(repo),
            state: &state,
            environment: [
                "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1",
                "WORKSPACES_PERF_AUTO_OPEN_NEW_WORKSPACE": "1",
            ],
            pendingRequest: nil,
            bootstrapController: MainWindowBootstrapController(),
            actions: makeActions(
                schedulePerfAutoSelect: { repo, shouldOpenNewWorkspace in
                    scheduledRepoID = repo.id
                    scheduledOpenNewWorkspace = shouldOpenNewWorkspace
                }
            )
        )

        #expect(!shouldContinue)
        #expect(state.didRunPerfAutoSelection)
        #expect(state.didRunPerfAutoOpenNewWorkspace)
        #expect(scheduledRepoID == repo.id)
        #expect(scheduledOpenNewWorkspace)
    }

    private func makeActions(
        clearDeepLink: @escaping () -> Void = {},
        clearLastSurface: @escaping () -> Void = {},
        discardPendingRemoteConnection: @escaping (String) -> Void = { _ in },
        importRepo: @escaping (String) -> Repo? = { _ in nil },
        selectWorkspace: @escaping (Workspace, URL?) -> Void = { _, _ in },
        selectRepoTerminal: @escaping (Repo, URL?) -> Void = { _, _ in },
        selectWebSource: @escaping (WebSource) -> Void = { _ in },
        applyLaunchSurface: @escaping (MainWindowLaunchSurface) -> Void = { _ in },
        schedulePerfAutoSelect: @escaping (Repo, Bool) -> Void = { _, _ in },
        focusWorkspaceWindow: @escaping () -> Void = {}
    ) -> MainWindowLaunchActionHandler.Actions {
        MainWindowLaunchActionHandler.Actions(
            clearDeepLink: clearDeepLink,
            clearLastSurface: clearLastSurface,
            discardPendingRemoteConnection: discardPendingRemoteConnection,
            importRepo: importRepo,
            selectWorkspace: selectWorkspace,
            selectRepoTerminal: selectRepoTerminal,
            selectWebSource: selectWebSource,
            applyLaunchSurface: applyLaunchSurface,
            schedulePerfAutoSelect: schedulePerfAutoSelect,
            focusWorkspaceWindow: focusWorkspaceWindow
        )
    }

    private func makeDeepLink(cwd: String, repoRoot: String? = nil) -> WorkspaceDeepLink? {
        let encodedCWD = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let encodedRepoRoot = repoRoot?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        let repoRootQuery = encodedRepoRoot.map { "&repo_root=\($0)" } ?? ""
        let url = URL(string: "workspaces://focus?cwd=\(encodedCWD)\(repoRootQuery)")!
        return WorkspaceDeepLink(url: url)
    }
}
