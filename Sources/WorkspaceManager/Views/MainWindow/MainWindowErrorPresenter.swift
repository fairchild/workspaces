import Foundation

/// One presentation model for main-window errors. Producers build a `MainWindowError` and
/// hand it to the presenter; the view renders a single alert from `current`. This is the seam
/// the main window converges its previously ad-hoc error paths (transient `.alert`, inline
/// banner, log-only) onto, so every surfaced error flows through one entry point.
///
/// Latest-wins: presenting while an error is showing replaces it, matching SwiftUI's behavior
/// of showing a single alert at a time.
struct MainWindowError: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String

    init(id: UUID = UUID(), title: String, message: String) {
        self.id = id
        self.title = title
        self.message = message
    }
}

struct MainWindowErrorPresenter {
    private(set) var current: MainWindowError?

    var isPresented: Bool { current != nil }

    mutating func present(_ error: MainWindowError) {
        current = error
    }

    mutating func present(title: String, message: String) {
        current = MainWindowError(title: title, message: message)
    }

    mutating func dismiss() {
        current = nil
    }
}
