import Foundation
import Testing

@testable import WorkspaceManager

@Suite("AppActivationPolicy")
struct AppActivationPolicyTests {
    @Test("Empty environment allows activation")
    @MainActor
    func emptyEnvironmentAllowsActivation() {
        let policy = AppActivationPolicy(environment: [:])
        #expect(policy.allowsActivation)
    }

    @Test("WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 suppresses activation")
    @MainActor
    func noActivateEnvVarSuppressesActivation() {
        let policy = AppActivationPolicy(environment: ["WORKSPACES_NO_ACTIVATE_ON_LAUNCH": "1"])
        #expect(!policy.allowsActivation)
    }

    @Test("Truthy strings suppress activation")
    @MainActor
    func truthyStringsSuppressActivation() {
        for raw in ["1", "true", "TRUE", "yes", "Yes", "on", " on "] {
            let policy = AppActivationPolicy(environment: ["WORKSPACES_NO_ACTIVATE_ON_LAUNCH": raw])
            #expect(!policy.allowsActivation, "\(raw) should suppress activation")
        }
    }

    @Test("Falsy strings allow activation")
    @MainActor
    func falsyStringsAllowActivation() {
        for raw in ["0", "false", "no", "off", "", "definitely-not"] {
            let policy = AppActivationPolicy(environment: ["WORKSPACES_NO_ACTIVATE_ON_LAUNCH": raw])
            #expect(policy.allowsActivation, "\(raw) should allow activation")
        }
    }

    @Test("CI presence suppresses activation regardless of value")
    @MainActor
    func ciSuppressesActivation() {
        for raw in ["1", "true", "github-actions", ""] {
            let policy = AppActivationPolicy(environment: ["CI": raw])
            #expect(!policy.allowsActivation, "CI=\(raw) should suppress activation")
        }
    }

    @Test("CI plus shared-desktop both suppress activation")
    @MainActor
    func ciAndSharedDesktopBothSuppress() {
        let policy = AppActivationPolicy(environment: [
            "CI": "1",
            "WORKSPACES_NO_ACTIVATE_ON_LAUNCH": "1",
        ])
        #expect(!policy.allowsActivation)
    }
}
