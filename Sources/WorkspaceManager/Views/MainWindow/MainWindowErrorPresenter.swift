import SwiftUI

/// Recovery-affordance hints for Lume-related failure messages: pure string
/// matching over the message, feeding both the production error alert's
/// recovery buttons and (in debug builds) the host-Lume smoke's failure events.
func lumeRecoveryHints(for message: String?) -> [String] {
    guard let message else { return [] }
    let normalized = message.lowercased()

    if normalized.contains("lume")
        || normalized.contains("macos vm")
        || normalized.contains("vm runtime")
        || normalized.contains("restore image")
        || normalized.contains("virtual machine not found")
    {
        return ["Open VM Runtime", "Open Lume Log"]
    }

    return []
}

/// One presentation model for main-window errors. Producers build a `MainWindowError` and
/// hand it to the presenter; a view renders a single alert from `current` via
/// `mainWindowErrorAlert`. This is the seam the main window and its sibling views (ContentView,
/// SidebarView) converge their previously ad-hoc transient `.alert` paths onto, so every
/// surfaced error flows through one entry point and one renderer.
///
/// Latest-wins: presenting while an error is showing replaces it, matching SwiftUI's behavior
/// of showing a single alert at a time. `dismiss()` clears `current`.
struct MainWindowError: Identifiable, Equatable {
    let id: UUID
    /// Where the error originated. Routes source-specific side effects (e.g. only
    /// workspace-operation failures notify the host-Lume smoke automation) without the view
    /// keeping a separate per-source message field.
    let source: MainWindowErrorSource
    let title: String
    let message: String
    /// Named recovery affordances the view maps to handlers, kept as data (not closures) so the
    /// model stays value-comparable and testable.
    let recoveryActions: [MainWindowErrorRecoveryAction]

    init(
        id: UUID = UUID(),
        source: MainWindowErrorSource,
        title: String,
        message: String,
        recoveryActions: [MainWindowErrorRecoveryAction] = []
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.message = message
        self.recoveryActions = recoveryActions
    }
}

enum MainWindowErrorSource: Equatable {
    case openInEditor
    case workspaceOperation
    case landing
    case sidebar
}

struct MainWindowErrorRecoveryAction: Identifiable, Equatable {
    enum Kind: Equatable {
        case openVMRuntime
        case openLumeLog
    }

    let id: UUID
    let title: String
    let kind: Kind

    init(id: UUID = UUID(), title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    /// The Lume recovery affordances offered for a failure message — the "Open VM Runtime" /
    /// "Open Lume Log" pair the sidebar showed whenever the message carried host-Lume recovery
    /// hints. Empty when the message has no such hints.
    static func lumeRecoveryActions(forMessage message: String?) -> [MainWindowErrorRecoveryAction] {
        guard !lumeRecoveryHints(for: message).isEmpty else { return [] }
        return [
            MainWindowErrorRecoveryAction(title: "Open VM Runtime", kind: .openVMRuntime),
            MainWindowErrorRecoveryAction(title: "Open Lume Log", kind: .openLumeLog),
        ]
    }
}

struct MainWindowErrorPresenter {
    private(set) var current: MainWindowError?

    var isPresented: Bool { current != nil }

    mutating func present(_ error: MainWindowError) {
        current = error
    }

    mutating func present(
        source: MainWindowErrorSource,
        title: String,
        message: String,
        recoveryActions: [MainWindowErrorRecoveryAction] = []
    ) {
        current = MainWindowError(
            source: source,
            title: title,
            message: message,
            recoveryActions: recoveryActions
        )
    }

    mutating func dismiss() {
        current = nil
    }

    /// The currently-presented message iff it came from `source`, else nil. Views observe this
    /// (an `Equatable` `String?`) to preserve each side effect's exact "message becomes non-nil"
    /// trigger semantics when several sources share one presenter.
    func message(from source: MainWindowErrorSource) -> String? {
        guard let current, current.source == source else { return nil }
        return current.message
    }

    /// Whether a newly-surfaced sidebar failure should re-notify the smoke automation. Before the
    /// seam, the sidebar's `errorMessage` was sticky (never cleared on dismiss), so an identical
    /// consecutive message did not re-fire `noteFailure`. The presenter clears on dismiss, so the
    /// sidebar tracks the last-notified message and consults this to keep that exact contract.
    static func shouldNoteFailure(message: String?, lastNoted: String?) -> Bool {
        guard let message else { return false }
        return message != lastNoted
    }
}

extension View {
    /// Renders `presenter`'s current error as the single main-window error alert. Recovery
    /// buttons come from the error's `recoveryActions`; `onRecoveryAction` maps a chosen action's
    /// kind to the view's handler. Any button dismisses the alert (SwiftUI clears the
    /// `isPresented` binding), which clears the presenter.
    func mainWindowErrorAlert(
        _ presenter: Binding<MainWindowErrorPresenter>,
        onRecoveryAction: @escaping (MainWindowErrorRecoveryAction.Kind) -> Void = { _ in }
    ) -> some View {
        modifier(MainWindowErrorAlertModifier(presenter: presenter, onRecoveryAction: onRecoveryAction))
    }
}

private struct MainWindowErrorAlertModifier: ViewModifier {
    @Binding var presenter: MainWindowErrorPresenter
    let onRecoveryAction: (MainWindowErrorRecoveryAction.Kind) -> Void

    func body(content: Content) -> some View {
        content.alert(
            presenter.current?.title ?? "Error",
            isPresented: Binding(
                get: { presenter.isPresented },
                set: { isPresented in
                    if !isPresented {
                        presenter.dismiss()
                    }
                }
            ),
            presenting: presenter.current
        ) { error in
            ForEach(error.recoveryActions) { action in
                Button(action.title) {
                    onRecoveryAction(action.kind)
                }
            }
            Button("OK", role: .cancel) {
                presenter.dismiss()
            }
        } message: { error in
            Text(error.message)
        }
    }
}
