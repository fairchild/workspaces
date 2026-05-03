//
//  SoftwareUpdateSettingsView.swift
//  WorkspaceManager
//
//  Transparent controls for privacy-preserving update checks.
//

import Sparkle
import SwiftUI

struct SoftwareUpdateSettingsView: View {
    private let updater: SPUUpdater
    @State private var automaticallyChecksForUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        self._automaticallyChecksForUpdates = State(
            initialValue: updater.automaticallyChecksForUpdates
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.headline)

            Toggle(
                "Automatically check for updates",
                isOn: $automaticallyChecksForUpdates
            )
            .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                updater.automaticallyChecksForUpdates = newValue
                if !newValue {
                    updater.automaticallyDownloadsUpdates = false
                }
            }

            Text(SoftwareUpdateConstants.automaticCheckDisclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Automatic downloads and silent installs are disabled. "
                    + "Installing an update always requires user confirmation."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Appcast")
                Spacer()
                Text(SoftwareUpdateConstants.feedURLString)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
        }
    }
}
