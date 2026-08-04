// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
import Foundation
import Testing

@testable import WorkspaceManager

@Suite("ExperimentalFeatures")
struct ExperimentalFeaturesTests {
    @Test("Features default off when no settings or environment override exist")
    func featuresDefaultOff() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!ExperimentalFeatures.isEnabled(.minimalToolbar, userDefaults: defaults, environment: [:]))
    }

    @Test("Master toggle suppresses enabled per-feature setting")
    func masterToggleSuppressesFeatureSetting() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: ExperimentalFeatures.masterEnabledKey)
        defaults.set(true, forKey: ExperimentalFeature.minimalToolbar.storageKey)

        #expect(!ExperimentalFeatures.isEnabled(.minimalToolbar, userDefaults: defaults, environment: [:]))
    }

    @Test("Feature is enabled when master and per-feature setting are enabled")
    func masterAndFeatureEnabledResolveOn() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: ExperimentalFeatures.masterEnabledKey)
        defaults.set(true, forKey: ExperimentalFeature.minimalToolbar.storageKey)

        #expect(ExperimentalFeatures.isEnabled(.minimalToolbar, userDefaults: defaults, environment: [:]))
    }

    @Test("Environment force-on wins over stored settings")
    func environmentForceOnWins() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: ExperimentalFeatures.masterEnabledKey)
        defaults.set(false, forKey: ExperimentalFeature.minimalToolbar.storageKey)

        #expect(
            ExperimentalFeatures.isEnabled(
                .minimalToolbar,
                userDefaults: defaults,
                environment: ["WORKSPACES_PERF_MINIMAL_TOOLBAR": "1"]
            )
        )
    }

    @Test("Invalid environment force-on values do not override settings")
    func invalidEnvironmentValuesDoNotOverrideSettings() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: ExperimentalFeatures.masterEnabledKey)
        defaults.set(true, forKey: ExperimentalFeature.minimalToolbar.storageKey)

        #expect(
            !ExperimentalFeatures.isEnabled(
                .minimalToolbar,
                userDefaults: defaults,
                environment: ["WORKSPACES_PERF_MINIMAL_TOOLBAR": "0"]
            )
        )
        #expect(
            !ExperimentalFeatures.isEnabled(
                .minimalToolbar,
                userDefaults: defaults,
                environment: ["WORKSPACES_PERF_MINIMAL_TOOLBAR": "maybe"]
            )
        )
    }

    @Test("Forced-on feature list reflects active environment overrides")
    func forcedOnFeatureListReflectsEnvironment() {
        #expect(ExperimentalFeatures.forcedOnFeatures(environment: [:]).isEmpty)
        #expect(
            ExperimentalFeatures.forcedOnFeatures(
                environment: ["WORKSPACES_PERF_MINIMAL_TOOLBAR": "true"]
            ) == [.minimalToolbar]
        )
    }

    @Test("Restore-sessions-on-launch defaults off and honors its force-on override")
    func restoreSessionsOnLaunchFlag() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!ExperimentalFeature.restoreSessionsOnLaunch.defaultEnabled)
        #expect(!ExperimentalFeatures.isEnabled(.restoreSessionsOnLaunch, userDefaults: defaults, environment: [:]))
        #expect(
            ExperimentalFeatures.isEnabled(
                .restoreSessionsOnLaunch,
                userDefaults: defaults,
                environment: ["WORKSPACES_RESTORE_SESSIONS_ON_LAUNCH": "1"]
            )
        )
    }

    @Test("Feature metadata has stable unique non-empty values")
    func featureMetadataIsUniqueAndNonEmpty() {
        let features = ExperimentalFeature.allCases

        #expect(Set(features.map(\.id)).count == features.count)
        #expect(Set(features.map(\.storageKey)).count == features.count)

        for feature in features {
            #expect(!feature.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!feature.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!feature.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(feature.storageKey.hasPrefix("experimentalFeatures."))
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ExperimentalFeaturesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
