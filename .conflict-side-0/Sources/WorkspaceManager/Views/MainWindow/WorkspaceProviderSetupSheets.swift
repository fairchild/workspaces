//
//  WorkspaceProviderSetupSheets.swift
//  WorkspaceManager
//
//  UI for provider-owned first-use setup and repair.
//

import SwiftUI

struct WorkspaceProviderSetupConfirmationSheet: View {
    let request: WorkspaceProviderSetupConfirmationRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.title)
                    .font(.title2.weight(.semibold))

                ForEach(Array(request.introductoryText.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .foregroundStyle(.secondary)
                }

                if let learnMoreLabel = request.learnMoreLabel,
                    let learnMoreURL = request.learnMoreURL
                {
                    Link(learnMoreLabel, destination: learnMoreURL)
                        .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(request.explanatoryStepsTitle)
                    .font(.headline)

                ForEach(Array(request.explanatorySteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(step)
                    }
                }
            }

            if let supplementaryText = request.supplementaryText {
                Text(supplementaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(request.footerText)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button(request.primaryButtonTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct WorkspaceProviderSetupProgressSheet: View {
    let presentation: WorkspaceProviderSetupProgressPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(presentation.title)
                .font(.title2.weight(.semibold))

            Text(presentation.action.summary)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text(presentation.step.label)
                    .font(.headline)
            }

            Text(presentation.bodyText)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
