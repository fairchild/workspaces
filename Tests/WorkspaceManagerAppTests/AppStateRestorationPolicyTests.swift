import Testing

@testable import WorkspaceManager

@Suite("App state restoration policy")
struct AppStateRestorationPolicyTests {
    @Test("preserves state by default")
    func preservesStateByDefault() {
        #expect(AppDelegate.shouldPreserveState(launchEnvironment: [:]))
    }

    @Test("diagnostic launches can disable state restoration")
    func diagnosticLaunchesCanDisableStateRestoration() {
        #expect(
            !AppDelegate.shouldPreserveState(
                launchEnvironment: ["WORKSPACES_DISABLE_STATE_RESTORATION": "1"]
            )
        )
    }
}
