import Foundation
import WorkspaceManagerCore

/// Main-actor handoff between ContentView's automation controller wiring and SidebarView's real
/// workspace-create helper. The bridge holds only a UI gesture closure and clears it on teardown,
/// so `workspace.create` fails closed when the sidebar/window is gone.
@MainActor
final class AutomationWorkspaceCreateGestureBridge: ObservableObject {
    typealias Handler = @MainActor (AutomationWorkspaceCreateCommand) async -> AutomationWorkspaceCreateOutcome

    private var handler: Handler?

    func install(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func clear() {
        handler = nil
    }

    func createWorkspace(_ command: AutomationWorkspaceCreateCommand) async -> AutomationWorkspaceCreateOutcome {
        guard let handler else {
            return .unsupported("No WorkSpaces sidebar is attached; workspace.create requires a live window.")
        }
        return await handler(command)
    }
}
