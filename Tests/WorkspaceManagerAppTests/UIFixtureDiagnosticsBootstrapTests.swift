import Testing

@testable import WorkspaceManager

@Suite("UIFixtureDiagnosticsBootstrap")
struct UIFixtureDiagnosticsBootstrapTests {
    @Test("Requires fixture mode and diagnostics flag")
    func requiresFixtureModeAndDiagnosticsFlag() {
        #expect(UIFixtureDiagnosticsBootstrapConfiguration.from(environment: [:]) == nil)
        #expect(
            UIFixtureDiagnosticsBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE_OPEN_DIAGNOSTICS": "1"]
            ) == nil
        )
        #expect(
            UIFixtureDiagnosticsBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE": "1"]
            ) == nil
        )
    }

    @Test("Accepts common truthy values")
    func acceptsCommonTruthyValues() {
        for value in ["1", "true", "yes", "on"] {
            #expect(
                UIFixtureDiagnosticsBootstrapConfiguration.from(
                    environment: [
                        "WORKSPACES_UI_FIXTURE": "1",
                        "WORKSPACES_UI_FIXTURE_OPEN_DIAGNOSTICS": value,
                    ]
                ) != nil
            )
        }
    }
}
