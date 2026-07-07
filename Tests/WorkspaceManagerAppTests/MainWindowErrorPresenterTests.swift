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
        presenter.present(title: "Could Not Open Editor", message: "boom")

        #expect(presenter.isPresented)
        #expect(presenter.current?.title == "Could Not Open Editor")
        #expect(presenter.current?.message == "boom")
    }

    @Test("Presenting while an error is shown replaces it (latest wins)")
    func presentReplacesLatest() {
        var presenter = MainWindowErrorPresenter()
        presenter.present(title: "First", message: "one")
        presenter.present(title: "Second", message: "two")

        #expect(presenter.current?.title == "Second")
        #expect(presenter.current?.message == "two")
    }

    @Test("Dismiss clears the current error")
    func dismissClears() {
        var presenter = MainWindowErrorPresenter()
        presenter.present(title: "Could Not Open Editor", message: "boom")
        presenter.dismiss()

        #expect(presenter.current == nil)
        #expect(presenter.isPresented == false)
    }
}
