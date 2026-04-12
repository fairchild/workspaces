import Foundation
import Testing

@testable import WorkspaceManager

@Suite("UIFixtureWebBootstrap")
struct UIFixtureWebBootstrapTests {
    @Test("Configuration requires fixture and web bootstrap flags")
    func configurationRequiresFlags() {
        #expect(UIFixtureWebBootstrapConfiguration.from(environment: [:]) == nil)
        #expect(
            UIFixtureWebBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE": "1"]
            ) == nil
        )
        #expect(
            UIFixtureWebBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE": "1"]
            ) == nil
        )
    }

    @Test("Configuration accepts boolean-like enable values")
    func configurationAcceptsTruthyValues() {
        let truthyValues = ["1", "true", "TRUE", "Yes", "on"]
        for value in truthyValues {
            let configuration = UIFixtureWebBootstrapConfiguration.from(
                environment: [
                    "WORKSPACES_UI_FIXTURE": "1",
                    "WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE": value,
                ]
            )
            #expect(configuration == UIFixtureWebBootstrapConfiguration(webSourceName: "Swift Docs"))
        }
    }

    @Test("Configuration defaults and trims source name")
    func configurationDefaultsAndTrimsSourceName() {
        let defaults = UIFixtureWebBootstrapConfiguration.from(
            environment: [
                "WORKSPACES_UI_FIXTURE": "1",
                "WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE": "1",
            ]
        )
        #expect(defaults == UIFixtureWebBootstrapConfiguration(webSourceName: "Swift Docs"))

        let custom = UIFixtureWebBootstrapConfiguration.from(
            environment: [
                "WORKSPACES_UI_FIXTURE": "1",
                "WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE": "true",
                "WORKSPACES_UI_FIXTURE_WEB_SOURCE": "  API Docs  ",
            ]
        )
        #expect(custom == UIFixtureWebBootstrapConfiguration(webSourceName: "API Docs"))
    }

    @Test("Configuration ignores unsupported enable values")
    func configurationRejectsFalseyValues() {
        let falseyValues = ["0", "false", "no", "off", "maybe", " "]
        for value in falseyValues {
            let configuration = UIFixtureWebBootstrapConfiguration.from(
                environment: [
                    "WORKSPACES_UI_FIXTURE": "1",
                    "WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE": value,
                ]
            )
            #expect(configuration == nil)
        }
    }
}
