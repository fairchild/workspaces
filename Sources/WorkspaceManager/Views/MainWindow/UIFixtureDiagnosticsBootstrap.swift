import Foundation

struct UIFixtureDiagnosticsBootstrapConfiguration: Equatable, Sendable {
    static let flagKey = "WORKSPACES_UI_FIXTURE_OPEN_DIAGNOSTICS"

    static func from(environment: [String: String]) -> Self? {
        guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
        guard enabled(environment[flagKey]) else { return nil }
        return Self()
    }

    private static func enabled(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "true", "yes", "on"].contains(value)
    }
}
