import Testing

@testable import WorkspaceManager

@Suite("UIFixtureTerminalTabBootstrap")
struct UIFixtureTerminalTabBootstrapTests {
    @Test("Requires fixture mode and a repository name")
    func requiresFixtureModeAndRepositoryName() {
        #expect(UIFixtureTerminalTabBootstrapConfiguration.from(environment: [:]) == nil)
        #expect(
            UIFixtureTerminalTabBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE_CMD_T_REPO": "workspaces"]
            ) == nil
        )
        #expect(
            UIFixtureTerminalTabBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE": "1"]
            ) == nil
        )
    }

    @Test("Stages a repository overview without triggering Cmd-T by default")
    func stagesRepositoryOverview() throws {
        let configuration = try #require(
            UIFixtureTerminalTabBootstrapConfiguration.from(
                environment: [
                    "WORKSPACES_UI_FIXTURE": "1",
                    "WORKSPACES_UI_FIXTURE_CMD_T_REPO": " workspaces ",
                ]
            )
        )

        #expect(configuration.repoName == "workspaces")
        #expect(!configuration.createsTerminalTab)
    }

    @Test("Accepts common truthy Cmd-T trigger values")
    func acceptsCommonTriggerValues() throws {
        for value in ["1", "true", "yes", "on"] {
            let configuration = try #require(
                UIFixtureTerminalTabBootstrapConfiguration.from(
                    environment: [
                        "WORKSPACES_UI_FIXTURE": "1",
                        "WORKSPACES_UI_FIXTURE_CMD_T_REPO": "workspaces",
                        "WORKSPACES_UI_FIXTURE_TRIGGER_CMD_T": value,
                    ]
                )
            )
            #expect(configuration.createsTerminalTab)
        }
    }
}
