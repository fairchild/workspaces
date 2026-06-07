import Combine
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("AppCommandState")
struct AppCommandStateTests {
    @Test("new workspace availability only publishes when availability changes")
    func newWorkspaceAvailabilityOnlyPublishesWhenAvailabilityChanges() {
        let state = AppCommandState()
        var emissions = 0
        let cancellable = state.objectWillChange.sink { _ in
            emissions += 1
        }
        defer { cancellable.cancel() }

        state.setNewWorkspaceAction({})
        #expect(state.canCreateWorkspace)
        #expect(emissions == 1)

        state.setNewWorkspaceAction({})
        #expect(state.canCreateWorkspace)
        #expect(emissions == 1)

        state.setNewWorkspaceAction(nil)
        #expect(!state.canCreateWorkspace)
        #expect(emissions == 2)
    }

    @Test("main window actions only publish when availability changes")
    func mainWindowActionsOnlyPublishWhenAvailabilityChanges() {
        let state = AppCommandState()
        var emissions = 0
        let cancellable = state.objectWillChange.sink { _ in
            emissions += 1
        }
        defer { cancellable.cancel() }

        let availability = MainWindowCommandAvailability(
            canToggleSidebar: true,
            canToggleInspector: false,
            canToggleTerminalPanel: false,
            canCreateTerminalTab: true,
            canCloseTerminalTab: true,
            canSelectNextTerminalTab: false,
            canSelectPreviousTerminalTab: false,
            canOpenInEditor: true,
            canOpenInBrowser: false,
            canReloadWebSource: false,
            canOpenDesktop: false,
            canRevealInFinder: false,
            canCopyPath: false,
            canOpenCommandPalette: true,
            canOpenCommandRunner: true
        )

        state.setMainWindowActions(
            MainWindowFocusedActions(
                toggleSidebar: {},
                toggleInspector: nil,
                toggleTerminalPanel: nil,
                newTerminalTab: {},
                closeTerminalTab: {},
                selectNextTerminalTab: nil,
                selectPreviousTerminalTab: nil,
                openInEditor: {},
                openInBrowser: nil,
                reloadWebSource: nil,
                openDesktop: nil,
                revealInFinder: nil,
                copyPath: nil
            ),
            availability: availability
        )
        #expect(state.mainWindowAvailability == availability)
        #expect(emissions == 1)

        state.setMainWindowActions(
            MainWindowFocusedActions(
                toggleSidebar: {},
                toggleInspector: nil,
                toggleTerminalPanel: nil,
                newTerminalTab: {},
                closeTerminalTab: {},
                selectNextTerminalTab: nil,
                selectPreviousTerminalTab: nil,
                openInEditor: {},
                openInBrowser: nil,
                reloadWebSource: nil,
                openDesktop: nil,
                revealInFinder: nil,
                copyPath: nil
            ),
            availability: availability
        )
        #expect(state.mainWindowAvailability == availability)
        #expect(emissions == 1)

        state.clearMainWindowActions()
        #expect(state.mainWindowAvailability == .empty)
        #expect(emissions == 2)
    }
}
