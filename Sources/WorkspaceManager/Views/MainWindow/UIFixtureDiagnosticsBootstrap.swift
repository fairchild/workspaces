import Foundation

/// Launch-surface request for the diagnostics fixture. The configuration type stays in every
/// build because the launch-surface wiring names it; only the environment parser is debug-only,
/// so release binaries carry neither the arming keys nor a way to arm them (#1237, following
/// the #1235 harness gate).
struct UIFixtureDiagnosticsBootstrapConfiguration: Equatable, Sendable {
    #if DEBUG
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
    #else
        static func from(environment: [String: String]) -> Self? { nil }
    #endif
}
