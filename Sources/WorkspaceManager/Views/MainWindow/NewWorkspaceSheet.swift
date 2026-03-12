//
//  NewWorkspaceSheet.swift
//  WorkspaceManager
//
//  Sheet for creating a new workspace from a repository.
//

import SwiftUI
import WorkspaceManagerCore

struct NewWorkspaceSheet: View {
    let repo: Repo
    let supportsDaytonaCreation: Bool
    let supportsSSHCreation: Bool
    let isDaytonaAvailable: Bool
    let isCreateDisabled: Bool
    let onCreate: (NewWorkspaceRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var backend: WorkspaceBackendChoice = .local
    @State private var isCreating = false

    @State private var sshHost = ""
    @State private var sshUser = ""
    @State private var sshPort = 22
    @State private var sshWorkingDirectory = ""
    @State private var composeEnabled = false
    @State private var composeFilesRaw = ""
    @State private var composeService = ""

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
        trimmed(name)
    }

    private var repoRemoteURL: String? {
        let trimmedRemoteURL = repo.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedRemoteURL, !trimmedRemoteURL.isEmpty else { return nil }
        return trimmedRemoteURL
    }

    private var parsedComposeFiles: [String] {
        composeFilesRaw
            .split { $0 == "," || $0.isNewline }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var availableBackends: [WorkspaceBackendChoice] {
        var choices: [WorkspaceBackendChoice] = [.local]
        if supportsDaytonaCreation {
            choices.append(.daytona)
        }
        if supportsSSHCreation {
            choices.append(.sshHost)
        }
        return choices
    }

    private var sanitizedWorkspaceNameComponent: String {
        WorkspaceService.sanitizeWorkspaceNameComponent(trimmedName)
    }

    private var defaultSSHWorkingDirectory: String {
        let repoComponent = sanitizedPathComponent(repo.name, fallback: "repo")
        let workspaceComponent = sanitizedPathComponent(
            trimmedName.isEmpty ? suggestedName : trimmedName,
            fallback: "workspace"
        )
        return "~/workspaces/\(repoComponent)/\(workspaceComponent)"
    }

    private var requestValidationMessage: String? {
        guard !trimmedName.isEmpty else {
            return "Enter a workspace name."
        }
        guard WorkspaceService.isValidWorkspaceNameComponent(sanitizedWorkspaceNameComponent) else {
            return "Enter a valid workspace name."
        }

        switch backend {
        case .local:
            return nil
        case .daytona:
            guard supportsDaytonaCreation else {
                return "Daytona workspace creation is unavailable in this build."
            }
            return isDaytonaAvailable ? nil : "Daytona is not available on this system."
        case .sshHost:
            guard supportsSSHCreation else {
                return "SSH host workspaces are unavailable in this build."
            }
            guard !trimmed(sshHost).isEmpty else {
                return "Enter an SSH host."
            }
            guard (1...65535).contains(sshPort) else {
                return "Enter an SSH port between 1 and 65535."
            }
            guard repoRemoteURL != nil else {
                return "This repository needs a remote URL before you can create an SSH workspace."
            }
            guard !composeEnabled || !parsedComposeFiles.isEmpty else {
                return "Enter at least one Compose file path."
            }
            guard !composeEnabled || !trimmed(composeService).isEmpty else {
                return "Enter a Compose service."
            }
            return nil
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
                backend: .sshHost(
                    SSHHostWorkspaceRequest(
                        ssh: SSHWorkspaceMetadata(
                            host: trimmed(sshHost),
                            user: trimmedOrNil(sshUser),
                            port: sshPort,
                            authMode: "ssh-agent",
                            workingDir: trimmedOrNil(sshWorkingDirectory)
                        ),
                        compose: composeEnabled
                            ? ComposeWorkspaceMetadata(
                                composeFiles: parsedComposeFiles,
                                service: trimmed(composeService)
                            )
                            : nil
                    )
                )
            )
        }
    }

    private var descriptionText: String {
        switch backend {
        case .local:
            return backend.summary
        case .daytona:
            if !supportsDaytonaCreation {
                return backend.summary + " This build does not include Daytona creation support."
            }
            if !isDaytonaAvailable {
                return backend.summary + " Daytona is currently unavailable."
            }
            return backend.summary
        case .sshHost:
            if !supportsSSHCreation {
                return backend.summary + " This build does not include SSH creation support."
            }
            return backend.summary + " SSH auth is agent-only in this branch."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                Section("Workspace") {
                    TextField("Workspace Name", text: $name)

                    Picker("Environment", selection: $backend) {
                        ForEach(availableBackends) { choice in
                            Text(choice.label)
                                .tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if backend.usesSSHConfiguration {
                    sshSection
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
        .frame(width: 500, height: 560)
        .onAppear {
            if name.isEmpty {
                name = suggestedName
            }
            if !availableBackends.contains(backend) {
                backend = availableBackends.first ?? .local
            }
        }
        .onChange(of: availableBackends) { _, choices in
            if !choices.contains(backend) {
                backend = choices.first ?? .local
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
        Section("SSH Host") {
            TextField("Host", text: $sshHost)
            TextField("User", text: $sshUser)
            TextField("Port", value: $sshPort, format: .number)
            TextField("Working Directory (Optional)", text: $sshWorkingDirectory)

            Text("Defaults to \(defaultSSHWorkingDirectory)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Use Docker Compose", isOn: $composeEnabled)

            if composeEnabled {
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

                TextField("Compose Service", text: $composeService)
            }

            if repoRemoteURL == nil {
                Text(
                    "SSH workspaces require a repository remote URL so the "
                        + "remote checkout can be cloned on first connect."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmedValue = trimmed(value)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func sanitizedPathComponent(_ value: String, fallback: String) -> String {
        let sanitized = WorkspaceService.sanitizeWorkspaceNameComponent(value)
        guard WorkspaceService.isValidWorkspaceNameComponent(sanitized) else {
            return fallback
        }
        return sanitized
    }
}
