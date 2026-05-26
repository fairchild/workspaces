//
//  ExperimentalFeaturesSettingsView.swift
//  WorkspaceManager
//

import SwiftUI

struct ExperimentalFeaturesSettingsView: View {
    @AppStorage(ExperimentalFeatures.masterEnabledKey)
    private var experimentalFeaturesEnabled: Bool = ExperimentalFeatures.defaultMasterEnabled

    private var forcedOnFeatures: [ExperimentalFeature] {
        ExperimentalFeatures.forcedOnFeatures()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Experimental Features", isOn: $experimentalFeaturesEnabled)
                .accessibilityIdentifier("settings.experimental.master-toggle")

            Text(
                "Try work-in-progress UI. Turning this off hides Settings-controlled experiments "
                    + "without clearing individual choices."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if !forcedOnFeatures.isEmpty {
                forcedOnNotice
            }

            if experimentalFeaturesEnabled {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ExperimentalFeature.allCases) { feature in
                        ExperimentalFeatureToggleRow(feature: feature)
                    }
                }
                .padding(.top, 2)
                .accessibilityIdentifier("settings.experimental.list")
            }
        }
        .accessibilityIdentifier("settings.experimental.section")
    }

    private var forcedOnNotice: some View {
        Label {
            Text(
                "Forced on for this launch: "
                    + forcedOnFeatures.map(\.title).joined(separator: ", ")
            )
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("settings.experimental.force-on-note")
    }
}

private struct ExperimentalFeatureToggleRow: View {
    let feature: ExperimentalFeature

    @AppStorage private var isEnabled: Bool

    init(feature: ExperimentalFeature) {
        self.feature = feature
        _isEnabled = AppStorage(wrappedValue: feature.defaultEnabled, feature.storageKey)
    }

    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.callout)

                Text(feature.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if ExperimentalFeatures.isForcedOn(feature),
                    let key = feature.forceOnEnvironmentKey
                {
                    Text("Forced on by \(key) for this launch.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityIdentifier("settings.experimental.feature.\(feature.rawValue)")
    }
}

#Preview {
    Form {
        Section {
            ExperimentalFeaturesSettingsView()
        } header: {
            Text("Experimental Features")
        }
    }
    .formStyle(.grouped)
    .frame(width: 560)
}
