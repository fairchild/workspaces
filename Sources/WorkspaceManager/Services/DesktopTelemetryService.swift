import Foundation
import PostHog

enum DesktopTelemetryEvent: String {
    case appLaunched = "desktop_app_launched"
    case repoAdded = "desktop_repo_added"
    case workspaceCreated = "desktop_workspace_created"
    case workspaceOpened = "desktop_workspace_opened"
    case webSourceCreated = "desktop_web_source_created"
    case editorOpened = "desktop_editor_opened"
}

struct DesktopTelemetryConfiguration: Equatable {
    let apiKey: String
    let host: String
    let debug: Bool
}

enum DesktopTelemetryConfigurationResolver {
    private static let doNotTrackEnvironmentKey = "DO_NOT_TRACK"
    private static let apiKeyEnvironmentKey = "WORKSPACES_POSTHOG_API_KEY"
    private static let hostEnvironmentKey = "WORKSPACES_POSTHOG_HOST"
    private static let debugEnvironmentKey = "WORKSPACES_POSTHOG_DEBUG"
    private static let apiKeyInfoKey = "PostHogAPIKey"
    private static let hostInfoKey = "PostHogHost"
    private static let defaultHost = "https://us.i.posthog.com"

    static func resolve(
        environment: [String: String],
        infoDictionary: [String: Any]
    ) -> DesktopTelemetryConfiguration? {
        guard !isEnabledValue(environment[doNotTrackEnvironmentKey]) else {
            return nil
        }

        guard
            let apiKey = normalizedValue(environment[apiKeyEnvironmentKey])
                ?? normalizedValue(infoDictionary[apiKeyInfoKey] as? String)
        else {
            return nil
        }

        let host =
            normalizedValue(environment[hostEnvironmentKey])
            ?? normalizedValue(infoDictionary[hostInfoKey] as? String)
            ?? defaultHost
        let debug = isEnabledValue(environment[debugEnvironmentKey])

        return DesktopTelemetryConfiguration(apiKey: apiKey, host: host, debug: debug)
    }

    private static func normalizedValue(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func isEnabledValue(_ rawValue: String?) -> Bool {
        guard let normalized = normalizedValue(rawValue)?.lowercased() else {
            return false
        }

        switch normalized {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

final class DesktopTelemetryService {
    static let disabled = DesktopTelemetryService()

    let isEnabled: Bool

    private let defaultProperties: [String: Any]

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        userDefaults: UserDefaults = .standard,
        buildIdentity: AppBuildIdentity = .current
    ) -> DesktopTelemetryService {
        guard
            let configuration = DesktopTelemetryConfigurationResolver.resolve(
                environment: environment,
                infoDictionary: infoDictionary
            )
        else {
            return .disabled
        }

        return DesktopTelemetryService(
            configuration: configuration,
            userDefaults: userDefaults,
            buildIdentity: buildIdentity,
            infoDictionary: infoDictionary
        )
    }

    private init() {
        self.isEnabled = false
        self.defaultProperties = [:]
    }

    private init(
        configuration: DesktopTelemetryConfiguration,
        userDefaults: UserDefaults,
        buildIdentity: AppBuildIdentity,
        infoDictionary: [String: Any]
    ) {
        self.isEnabled = true
        self.defaultProperties = Self.defaultProperties(
            buildIdentity: buildIdentity,
            infoDictionary: infoDictionary
        )

        let config = PostHogConfig(apiKey: configuration.apiKey, host: configuration.host)
        config.debug = configuration.debug
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        PostHogSDK.shared.setup(config)

        let distinctID = Self.resolveDistinctID(userDefaults: userDefaults)
        PostHogSDK.shared.identify(distinctID, userProperties: defaultProperties)
        PostHogSDK.shared.capture(DesktopTelemetryEvent.appLaunched.rawValue, properties: defaultProperties)
    }

    func capture(
        _ event: DesktopTelemetryEvent,
        properties: [String: Any] = [:]
    ) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(
            event.rawValue,
            properties: defaultProperties.merging(properties) { _, newValue in newValue }
        )
    }

    private static func resolveDistinctID(userDefaults: UserDefaults) -> String {
        let key = "posthogDistinctID"
        if let existing = userDefaults.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let distinctID = "macos-\(UUID().uuidString.lowercased())"
        userDefaults.set(distinctID, forKey: key)
        return distinctID
    }

    private static func defaultProperties(
        buildIdentity: AppBuildIdentity,
        infoDictionary: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "app_platform": "macos",
            "build_channel": buildIdentity.channel.rawValue,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]

        if let version = infoDictionary["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        {
            properties["app_version"] = version
        }

        if let buildNumber = infoDictionary["CFBundleVersion"] as? String,
            !buildNumber.isEmpty
        {
            properties["app_build"] = buildNumber
        }

        return properties
    }
}
