//
//  ExperimentalFeatures.swift
//  WorkspaceManager
//

import Foundation
import SwiftUI

enum ExperimentalFeature: String, CaseIterable, Identifiable {
    case automationAPI = "automationAPI"
    case minimalToolbar = "minimalToolbar"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automationAPI:
            return "Automation API"
        case .minimalToolbar:
            return "Minimal Toolbar"
        }
    }

    var description: String {
        switch self {
        case .automationAPI:
            return "Expose a local same-user socket so terminal tiles can inspect and arrange their WorkSpaces shell."
        case .minimalToolbar:
            return "Hide secondary toolbar controls so terminal surfaces stay closer to the canvas."
        }
    }

    var storageKey: String {
        "experimentalFeatures.\(rawValue).enabled"
    }

    var defaultEnabled: Bool {
        false
    }

    var forceOnEnvironmentKey: String? {
        switch self {
        case .automationAPI:
            return "WORKSPACES_AUTOMATION_API"
        case .minimalToolbar:
            return "WORKSPACES_PERF_MINIMAL_TOOLBAR"
        }
    }
}

enum ExperimentalFeatures {
    static let masterEnabledKey = "experimentalFeatures.enabled"
    static let defaultMasterEnabled = false

    static func isEnabled(
        _ feature: ExperimentalFeature,
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isEnabled(
            feature,
            masterEnabled: bool(
                forKey: masterEnabledKey,
                defaultValue: defaultMasterEnabled,
                userDefaults: userDefaults
            ),
            featureEnabled: bool(
                forKey: feature.storageKey,
                defaultValue: feature.defaultEnabled,
                userDefaults: userDefaults
            ),
            environment: environment
        )
    }

    static func isEnabled(
        _ feature: ExperimentalFeature,
        masterEnabled: Bool,
        featureEnabled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if isForcedOn(feature, environment: environment) {
            return true
        }

        return masterEnabled && featureEnabled
    }

    static func isForcedOn(
        _ feature: ExperimentalFeature,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard
            let key = feature.forceOnEnvironmentKey,
            let rawValue = environment[key]
        else {
            return false
        }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static func forcedOnFeatures(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ExperimentalFeature] {
        ExperimentalFeature.allCases.filter { isForcedOn($0, environment: environment) }
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        userDefaults: UserDefaults
    ) -> Bool {
        guard let storedValue = userDefaults.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return storedValue
    }
}

@propertyWrapper
struct ExperimentalFeatureFlag: DynamicProperty {
    private let feature: ExperimentalFeature
    private let environment: [String: String]

    @AppStorage(ExperimentalFeatures.masterEnabledKey)
    private var masterEnabled: Bool = ExperimentalFeatures.defaultMasterEnabled

    @AppStorage private var featureEnabled: Bool

    init(
        _ feature: ExperimentalFeature,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.feature = feature
        self.environment = environment
        _featureEnabled = AppStorage(wrappedValue: feature.defaultEnabled, feature.storageKey)
    }

    var wrappedValue: Bool {
        ExperimentalFeatures.isEnabled(
            feature,
            masterEnabled: masterEnabled,
            featureEnabled: featureEnabled,
            environment: environment
        )
    }
}
