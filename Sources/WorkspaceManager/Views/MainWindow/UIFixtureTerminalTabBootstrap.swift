import Foundation

/// Deterministic repository-overview state for Cmd-T evidence. The parser is debug-only so
/// release builds retain the inert configuration type without carrying fixture arming keys.
struct UIFixtureTerminalTabBootstrapConfiguration: Equatable, Sendable {
    let repoName: String
    /// How many times the fixture presses Cmd-T after selecting the overview. The second
    /// press opens a sibling tab beside the terminal the first one opened.
    let terminalTabTriggers: Int

    var createsTerminalTab: Bool { terminalTabTriggers > 0 }

    #if DEBUG
        static let repoEnvKey = "WORKSPACES_UI_FIXTURE_CMD_T_REPO"
        static let triggerEnvKey = "WORKSPACES_UI_FIXTURE_TRIGGER_CMD_T"

        static func from(environment: [String: String]) -> Self? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
            guard let repoName = normalizedValue(environment[repoEnvKey]) else { return nil }
            return Self(
                repoName: repoName,
                terminalTabTriggers: triggerCount(environment[triggerEnvKey])
            )
        }

        private static func normalizedValue(_ rawValue: String?) -> String? {
            guard let rawValue else { return nil }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        private static func triggerCount(_ rawValue: String?) -> Int {
            guard let rawValue else { return 0 }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "on"].contains(value) { return 1 }
            return min(max(Int(value) ?? 0, 0), 4)
        }
    #else
        static func from(environment: [String: String]) -> Self? { nil }
    #endif
}
