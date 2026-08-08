import Foundation
import WorkspaceManagerCore

/// The main window's host-session activation, carried with its parameter names intact.
/// A bare `(HostTerminalSessionKey, URL, String?) -> HostTerminalSession` closure reads as
/// three positional arguments at every call site — and the one that most needs a name is the
/// trailing `customCommand`, which is `nil` on the paths that launch a plain shell.
struct MainWindowHostSessionActivator {
    private let activate: @MainActor (HostTerminalSessionKey, URL, String?) -> HostTerminalSession

    init(_ activate: @escaping @MainActor (HostTerminalSessionKey, URL, String?) -> HostTerminalSession) {
        self.activate = activate
    }

    @MainActor
    func callAsFunction(
        key: HostTerminalSessionKey,
        directory: URL,
        customCommand: String?
    ) -> HostTerminalSession {
        activate(key, directory, customCommand)
    }
}
