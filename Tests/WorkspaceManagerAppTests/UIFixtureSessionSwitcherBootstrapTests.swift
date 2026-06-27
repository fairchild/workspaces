import Testing

@testable import WorkspaceManager

@Suite("UIFixtureSessionSwitcherBootstrap")
struct UIFixtureSessionSwitcherBootstrapTests {
    @Test("Requires fixture mode and session switcher flag")
    func requiresFixtureModeAndSessionSwitcherFlag() {
        #expect(UIFixtureSessionSwitcherBootstrapConfiguration.from(environment: [:]) == nil)
        #expect(
            UIFixtureSessionSwitcherBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE_OPEN_SESSION_SWITCHER": "1"]
            ) == nil
        )
        #expect(
            UIFixtureSessionSwitcherBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE": "1"]
            ) == nil
        )
    }

    @Test("Accepts common truthy values")
    func acceptsCommonTruthyValues() {
        for value in ["1", "true", "yes", "on"] {
            #expect(
                UIFixtureSessionSwitcherBootstrapConfiguration.from(
                    environment: [
                        "WORKSPACES_UI_FIXTURE": "1",
                        "WORKSPACES_UI_FIXTURE_OPEN_SESSION_SWITCHER": value,
                    ]
                ) != nil
            )
        }
    }

    @Test("Rejects unsupported enable values")
    func rejectsUnsupportedEnableValues() {
        for value in ["0", "false", "no", "off", "maybe", " "] {
            #expect(
                UIFixtureSessionSwitcherBootstrapConfiguration.from(
                    environment: [
                        "WORKSPACES_UI_FIXTURE": "1",
                        "WORKSPACES_UI_FIXTURE_OPEN_SESSION_SWITCHER": value,
                    ]
                ) == nil
            )
        }
    }
}
