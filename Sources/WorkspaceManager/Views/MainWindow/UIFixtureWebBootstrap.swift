import Foundation

/// Launch-surface request for the web-source fixture: which source the app should open on
/// launch. The configuration type stays in every build because the launch-surface wiring names
/// it; only the environment parser is debug-only, so release binaries carry neither the arming
/// keys nor a way to arm them.
struct UIFixtureWebBootstrapConfiguration: Equatable, Sendable {
    let webSourceName: String

    #if DEBUG
        static func from(environment: [String: String]) -> Self? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
            guard enabled(environment["WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE"]) else { return nil }

            let webSourceName = normalizedValue(environment["WORKSPACES_UI_FIXTURE_WEB_SOURCE"]) ?? "Swift Docs"
            return Self(webSourceName: webSourceName)
        }

        private static func normalizedValue(_ rawValue: String?) -> String? {
            guard let rawValue else { return nil }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func enabled(_ rawValue: String?) -> Bool {
            guard let value = normalizedValue(rawValue)?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(value)
        }
    #else
        static func from(environment: [String: String]) -> Self? { nil }
    #endif
}
