import Foundation
import Testing

@testable import WorkspaceManager

@Suite("MainWindowErrorPresenter")
struct MainWindowErrorPresenterTests {
    @Test("A fresh presenter has nothing to show")
    func startsEmpty() {
        let presenter = MainWindowErrorPresenter()
        #expect(presenter.current == nil)
        #expect(presenter.isPresented == false)
    }

    @Test("Presenting an error makes it the current surfaced error")
    func presentSurfacesError() {
        var presenter = MainWindowErrorPresenter()
        presenter.present(source: .openInEditor, title: "Could Not Open Editor", message: "boom")

        #expect(presenter.isPresented)
        #expect(presenter.current?.source == .openInEditor)
        #expect(presenter.current?.title == "Could Not Open Editor")
        #expect(presenter.current?.message == "boom")
    }

    @Test("Presenting while an error is shown replaces it (latest wins)")
    func presentReplacesLatest() {
        var presenter = MainWindowErrorPresenter()
        presenter.present(source: .workspaceOperation, title: "First", message: "one")
        presenter.present(source: .landing, title: "Second", message: "two")

        #expect(presenter.current?.source == .landing)
        #expect(presenter.current?.title == "Second")
        #expect(presenter.current?.message == "two")
    }

    @Test("Dismiss clears the current error")
    func dismissClears() {
        var presenter = MainWindowErrorPresenter()
        presenter.present(source: .openInEditor, title: "Could Not Open Editor", message: "boom")
        presenter.dismiss()

        #expect(presenter.current == nil)
        #expect(presenter.isPresented == false)
    }

    // Source routing — a side effect observes only its own source's message, so several sources
    // can share one presenter without cross-firing each other's onChange hooks.

    @Test("message(from:) returns the message only for the matching source")
    func sourceRoutingMatches() {
        var presenter = MainWindowErrorPresenter()
        presenter.present(source: .workspaceOperation, title: "Could Not Open Workspace", message: "boom")

        #expect(presenter.message(from: .workspaceOperation) == "boom")
        #expect(presenter.message(from: .openInEditor) == nil)
        #expect(presenter.message(from: .landing) == nil)
    }

    @Test("message(from:) is nil once the error is dismissed")
    func sourceRoutingClearsOnDismiss() {
        var presenter = MainWindowErrorPresenter()
        presenter.present(source: .workspaceOperation, title: "Could Not Open Workspace", message: "boom")
        presenter.dismiss()

        #expect(presenter.message(from: .workspaceOperation) == nil)
    }

    @Test("message(from:) follows a latest-wins replacement to the new source")
    func sourceRoutingFollowsReplacement() {
        var presenter = MainWindowErrorPresenter()
        presenter.present(source: .workspaceOperation, title: "Workspace", message: "boom")
        presenter.present(source: .openInEditor, title: "Editor", message: "kaboom")

        #expect(presenter.message(from: .workspaceOperation) == nil)
        #expect(presenter.message(from: .openInEditor) == "kaboom")
    }

    // Recovery actions modeled as data — the sidebar's "Open VM Runtime" / "Open Lume Log" pair
    // is offered exactly when the message carries host-Lume recovery hints.

    @Test("Lume recovery actions are offered for a Lume failure message")
    func lumeRecoveryActionsForLumeMessage() {
        let actions = MainWindowErrorRecoveryAction.lumeRecoveryActions(
            forMessage: "Failed to start Lume VM: boom"
        )

        #expect(actions.map(\.kind) == [.openVMRuntime, .openLumeLog])
        #expect(actions.map(\.title) == ["Open VM Runtime", "Open Lume Log"])
    }

    @Test("No recovery actions for a message without Lume hints")
    func noRecoveryActionsForPlainMessage() {
        let plain = MainWindowErrorRecoveryAction.lumeRecoveryActions(forMessage: "Failed to delete workspace: boom")
        #expect(plain.isEmpty)
        #expect(MainWindowErrorRecoveryAction.lumeRecoveryActions(forMessage: nil).isEmpty)
    }

    // Sidebar sticky re-fire contract — an identical consecutive failure does not re-notify the
    // smoke automation, but a new or different message does.

    @Test("shouldNoteFailure fires for a new message and skips an identical repeat")
    func shouldNoteFailureContract() {
        #expect(MainWindowErrorPresenter.shouldNoteFailure(message: "boom", lastNoted: nil))
        #expect(MainWindowErrorPresenter.shouldNoteFailure(message: "boom", lastNoted: "boom") == false)
        #expect(MainWindowErrorPresenter.shouldNoteFailure(message: "kaboom", lastNoted: "boom"))
        #expect(MainWindowErrorPresenter.shouldNoteFailure(message: nil, lastNoted: "boom") == false)
    }
}
