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

    @Test("save document action only runs when enabled")
    func saveDocumentActionOnlyRunsWhenEnabled() {
        let state = AppCommandState()
        var saveCount = 0
        var emissions = 0
        let cancellable = state.objectWillChange.sink { _ in
            emissions += 1
        }
        defer { cancellable.cancel() }

        state.setSaveDocumentAction({ saveCount += 1 }, isEnabled: false)
        #expect(!state.canSaveDocument)
        #expect(emissions == 0)

        state.performSaveDocument()
        #expect(saveCount == 0)

        state.setSaveDocumentAction({ saveCount += 1 }, isEnabled: true)
        #expect(state.canSaveDocument)
        #expect(emissions == 1)

        state.performSaveDocument()
        #expect(saveCount == 1)

        state.clearSaveDocumentAction()
        #expect(!state.canSaveDocument)
        #expect(emissions == 2)
    }

    @Test("document edits state publishes dirty transitions and forwards the save hook")
    func documentEditsStatePublishesAndSaves() async {
        let state = AppCommandState()
        var emissions = 0
        let cancellable = state.objectWillChange.sink { _ in
            emissions += 1
        }
        defer { cancellable.cancel() }

        #expect(!state.hasUnsavedDocumentEdits)

        var saveCount = 0
        state.setDocumentEditsState(
            isDirty: true,
            save: {
                saveCount += 1
                return true
            })
        #expect(state.hasUnsavedDocumentEdits)
        #expect(emissions == 1)

        // Re-registering with the same dirty value re-binds the hook without a redundant emission.
        state.setDocumentEditsState(
            isDirty: true,
            save: {
                saveCount += 1
                return true
            })
        #expect(emissions == 1)

        let didSave = await state.saveDirtyDocument()
        #expect(didSave)
        #expect(saveCount == 1)

        state.clearDocumentEditsState()
        #expect(!state.hasUnsavedDocumentEdits)
        #expect(emissions == 2)
    }

    @Test("saveDirtyDocument reports success when no hook is registered")
    func saveDirtyDocumentDefaultsToSuccess() async {
        let state = AppCommandState()
        let didSave = await state.saveDirtyDocument()
        #expect(didSave)
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
            canOpenSessionSwitcher: true,
            canOpenCommandRunner: true,
            canSendFeedback: true,
            canOpenEmbeddedWebNext: true
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
