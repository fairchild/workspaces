//
//  LumeSetupSheets.swift
//  WorkspaceManager
//
//  UI for first-use Lume setup and repair.
//

import SwiftUI

struct LumeSetupConfirmationSheet: View {
    private let lumeDocsURL = URL(
        string: "https://cua.ai/docs/lume/guide/getting-started/introduction"
    )!

    let request: LumeSetupConfirmationRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.title)
                    .font(.title2.weight(.semibold))

                Text(
                    "Lume is an MIT open-source VM runtime that uses Apple's native Virtualization Framework to run macOS and Linux VMs at near-native speed on Apple Silicon."
                )
                .foregroundStyle(.secondary)

                Text(
                    "Workspaces needs it so it can create VM-backed workspaces, open an in-app terminal with `lume ssh`, and launch full desktop access via VNC."
                )
                .foregroundStyle(.secondary)

                Link("Learn more about Lume", destination: lumeDocsURL)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("What Workspaces will do")
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

            if let hostMatchDescription = request.hostMatchDescription {
                Text(hostMatchDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(
                "This is a one-time setup on this Mac. No admin access is required. After setup finishes, Workspaces will continue automatically."
            )
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

struct LumeSetupProgressSheet: View {
    let presentation: LumeSetupProgressPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preparing macOS VM Support")
                .font(.title2.weight(.semibold))

            Text(presentation.action.summary)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text(presentation.step.label)
                    .font(.headline)
            }

            Text("Workspaces is setting up the local Lume runtime and will continue automatically when it is ready.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
