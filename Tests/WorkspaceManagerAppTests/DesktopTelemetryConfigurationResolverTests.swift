import Testing
@testable import WorkspaceManager

struct DesktopTelemetryConfigurationResolverTests {
    @Test
    func prefersEnvironmentOverrides() {
        let configuration = DesktopTelemetryConfigurationResolver.resolve(
            environment: [
                "WORKSPACES_POSTHOG_API_KEY": "phc_env",
                "WORKSPACES_POSTHOG_HOST": "https://eu.i.posthog.com",
                "WORKSPACES_POSTHOG_DEBUG": "1",
            ],
            infoDictionary: [
                "PostHogAPIKey": "phc_info",
                "PostHogHost": "https://us.i.posthog.com",
            ]
        )

        #expect(
            configuration
                == DesktopTelemetryConfiguration(
                    apiKey: "phc_env",
                    host: "https://eu.i.posthog.com",
                    debug: true
                )
        )
    }

    @Test
    func fallsBackToInfoDictionaryValues() {
        let configuration = DesktopTelemetryConfigurationResolver.resolve(
            environment: [:],
            infoDictionary: [
                "PostHogAPIKey": "  phc_info  ",
                "PostHogHost": "  https://us.i.posthog.com  ",
            ]
        )

        #expect(
            configuration
                == DesktopTelemetryConfiguration(
                    apiKey: "phc_info",
                    host: "https://us.i.posthog.com",
                    debug: false
                )
        )
    }

    @Test
    func disablesTelemetryWithoutAPIKey() {
        let configuration = DesktopTelemetryConfigurationResolver.resolve(
            environment: [:],
            infoDictionary: [:]
        )

        #expect(configuration == nil)
    }

    @Test
    func respectsDoNotTrackEnvironmentVariable() {
        let configuration = DesktopTelemetryConfigurationResolver.resolve(
            environment: [
                "DO_NOT_TRACK": "1",
                "WORKSPACES_POSTHOG_API_KEY": "phc_env",
            ],
            infoDictionary: [:]
        )

        #expect(configuration == nil)
    }
}
