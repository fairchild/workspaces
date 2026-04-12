import Foundation

struct UIFixtureWebBootstrapConfiguration: Equatable, Sendable {
    let webSourceName: String

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
}
