import Foundation
import WorkspaceManagerCore

@MainActor
struct WorkspaceProviderSetupActionRunner {
    let coordinator: WorkspaceProviderSetupCoordinator

    @discardableResult
    func run(
        provider: any WorkspaceProviderProtocol,
        action: WorkspaceProviderSetupAction,
        afterSetup: (@MainActor () async -> Void)? = nil,
        perform: @escaping @MainActor () async -> Void
    ) async throws -> Bool {
        let intercepted = try await coordinator.prepareIfNeeded(
            provider: provider,
            action: action
        ) {
            await afterSetup?()
            await perform()
        }

        if intercepted {
            return true
        }

        await perform()
        return false
    }
}
