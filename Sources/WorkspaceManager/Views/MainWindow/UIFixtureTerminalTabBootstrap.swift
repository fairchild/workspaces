import Foundation

/// Deterministic repository-overview state for Cmd-T evidence. The parser is debug-only so
/// release builds retain the inert configuration type without carrying fixture arming keys.
struct UIFixtureTerminalTabBootstrapConfiguration: Equatable, Sendable {
    let repoName: String
    let createsTerminalTab: Bool

    #if DEBUG
        static let repoEnvKey = "WORKSPACES_UI_FIXTURE_CMD_T_REPO"
        static let triggerEnvKey = "WORKSPACES_UI_FIXTURE_TRIGGER_CMD_T"

        static func from(environment: [String: String]) -> Self? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
            guard let repoName = normalizedValue(environment[repoEnvKey]) else { return nil }
            return Self(
                repoName: repoName,
                createsTerminalTab: enabled(environment[triggerEnvKey])
            )
        }

        private static func normalizedValue(_ rawValue: String?) -> String? {
            guard let rawValue else { return nil }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        private static func enabled(_ rawValue: String?) -> Bool {
            guard let rawValue else { return false }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(value)
        }
    #else
        static func from(environment: [String: String]) -> Self? { nil }
    #endif
}
