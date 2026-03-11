//
//  NewWorkspaceSheet.swift
//  WorkspaceManager
//
//  Sheet for creating a new workspace from a repository
//

import SwiftUI
import WorkspaceManagerCore

struct NewWorkspaceSheet: View {
    let repo: Repo
    let isDaytonaBackendAvailable: Bool
    let isCreateDisabled: Bool
    let onCreate: (NewWorkspaceRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var backend: WorkspaceBackendChoice = .local
    @State private var isCreating = false

    @State private var sshHost = ""
    @State private var sshUser = ""
    @State private var sshPort = 22
    @State private var sshAuthentication: SSHAuthenticationChoice = .agent
    @State private var sshWorkingDirectory = ""

    @State private var kubernetesContext = ""
    @State private var kubernetesNamespace = ""
    @State private var kubernetesPod = ""
    @State private var kubernetesContainer = ""
    @State private var kubernetesImageTemplate = ""

    @State private var composeFilesRaw = ""
    @State private var composeService = ""
    @State private var composeStartupStrategy: ComposeStartupStrategy = .upThenExec

    private var suggestedName: String {
        let existingNames = Set(repo.workspaces.map { $0.name.lowercased() })
        var version = 1
        var candidate = "\(repo.name)-v\(version)"
        while existingNames.contains(candidate.lowercased()) {
            version += 1
            candidate = "\(repo.name)-v\(version)"
        }
        return candidate
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedComposeFiles: [String] {
        composeFilesRaw
            .split { $0 == "," || $0.isNewline }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var requestValidationMessage: String? {
        guard !trimmedName.isEmpty else {
            return "Enter a workspace name."
        }

        switch backend {
        case .local:
            return nil
        case .daytona:
            return isDaytonaBackendAvailable ? nil : "Daytona is not available on this system."
        case .sshHost:
            return trimmed(sshHost).isEmpty ? "Enter an SSH host." : nil
        case .kubernetesPod:
            guard !trimmed(kubernetesContext).isEmpty else {
                return "Enter a Kubernetes context."
            }
            if trimmed(kubernetesPod).isEmpty && trimmed(kubernetesImageTemplate).isEmpty {
                return "Enter a pod or an image template."
            }
            return nil
        case .sshCompose:
            if trimmed(sshHost).isEmpty {
                return "Enter an SSH host."
            }
            if parsedComposeFiles.isEmpty {
                return "Enter at least one Compose file path."
            }
            return trimmed(composeService).isEmpty ? "Enter a Compose service." : nil
        }
    }

    private var createRequest: NewWorkspaceRequest? {
        guard requestValidationMessage == nil else { return nil }

        switch backend {
        case .local:
            return NewWorkspaceRequest(name: trimmedName, backend: .local)
        case .daytona:
            return NewWorkspaceRequest(name: trimmedName, backend: .daytona)
        case .sshHost:
            return NewWorkspaceRequest(
                name: trimmedName,
                backend: .sshHost(sshMetadata)
            )
        case .kubernetesPod:
            return NewWorkspaceRequest(
                name: trimmedName,
                backend: .kubernetesPod(
                    KubernetesPodWorkspaceRequest(
                        context: trimmed(kubernetesContext),
                        namespace: trimmedOrNil(kubernetesNamespace),
                        pod: trimmedOrNil(kubernetesPod),
                        container: trimmedOrNil(kubernetesContainer),
                        imageTemplate: trimmedOrNil(kubernetesImageTemplate)
                    )
                )
            )
        case .sshCompose:
            return NewWorkspaceRequest(
                name: trimmedName,
                backend: .sshCompose(
                    SSHComposeWorkspaceRequest(
                        ssh: sshMetadata,
                        composeFiles: parsedComposeFiles,
                        service: trimmed(composeService),
                        startupStrategy: composeStartupStrategy
                    )
                )
            )
        }
    }

    private var sshMetadata: SSHWorkspaceMetadata {
        SSHWorkspaceMetadata(
            host: trimmed(sshHost),
            user: trimmedOrNil(sshUser),
            port: sshPort,
            authMode: sshAuthentication.rawValue,
            workingDir: trimmedOrNil(sshWorkingDirectory)
        )
    }

    private var descriptionText: String {
        let note: String
        if backend.requiresDaytonaAvailability && !isDaytonaBackendAvailable {
            note = " Daytona is currently unavailable."
        } else if !backend.supportsCreationFlow {
            note = " Configuration is captured now, but backend provisioning is not implemented yet."
        } else {
            note = ""
        }
        return backend.summary + note
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                Section("Workspace") {
                    TextField("Workspace Name", text: $name)

                    Picker("Environment", selection: $backend) {
                        ForEach(WorkspaceBackendChoice.allCases) { choice in
                            Label(choice.label, systemImage: choice.icon)
                                .tag(choice)
                        }
                    }

                    Text(descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if backend.usesSSHConfiguration {
                    sshSection
                }

                if backend.usesKubernetesConfiguration {
                    kubernetesSection
                }

                if backend.usesComposeConfiguration {
                    composeSection
                }

                if let requestValidationMessage {
                    Section {
                        Text(requestValidationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    guard let createRequest else { return }
                    isCreating = true
                    onCreate(createRequest)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(createRequest == nil || isCreating || isCreateDisabled)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
        .onAppear {
            if name.isEmpty {
                name = suggestedName
            }
        }
        .onChange(of: isDaytonaBackendAvailable) { _, isAvailable in
            if !isAvailable && backend == .daytona {
                backend = .local
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: backend.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }

            Text("New Workspace")
                .font(.title3)
                .fontWeight(.semibold)

            Text("from \(repo.name)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var sshSection: some View {
        Section("SSH") {
            TextField("Host", text: $sshHost)
            TextField("User", text: $sshUser)
            TextField("Port", value: $sshPort, format: .number)

            Picker("Authentication", selection: $sshAuthentication) {
                ForEach(SSHAuthenticationChoice.allCases) { choice in
                    Text(choice.label)
                        .tag(choice)
                }
            }

            TextField("Working Directory", text: $sshWorkingDirectory)
        }
    }

    private var kubernetesSection: some View {
        Section("Kubernetes") {
            TextField("Context", text: $kubernetesContext)
            TextField("Namespace", text: $kubernetesNamespace)
            TextField("Pod", text: $kubernetesPod)
            TextField("Container", text: $kubernetesContainer)
            TextField("Image Template", text: $kubernetesImageTemplate)
        }
    }

    private var composeSection: some View {
        Section("Compose") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Compose File Paths")
                    .font(.callout)
                TextEditor(text: $composeFilesRaw)
                    .font(.body.monospaced())
                    .frame(minHeight: 64, maxHeight: 96)
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2))
                    }
                Text("Separate multiple paths with commas or new lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Service", text: $composeService)

            Picker("Startup Strategy", selection: $composeStartupStrategy) {
                ForEach(ComposeStartupStrategy.allCases) { strategy in
                    Text(strategy.label)
                        .tag(strategy)
                }
            }

            Text(composeStartupStrategy.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmedValue = trimmed(value)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
