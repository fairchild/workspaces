//
//  NewWorkspaceSheet.swift
//  WorkspaceManager
//
//  Sheet for creating a new workspace from a repository
//

import SwiftUI
import WorkspaceManagerCore

struct WorkspaceEnvironmentSheetOption: Identifiable {
    enum Kind: String, Identifiable {
        case local
        case cloudLinux
        case macOSVM
        case linuxVM

        var id: String { rawValue }
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let description: String
    let iconName: String
    let providerID: String
    let guestOS: WorkspaceGuestOS?
    let isAvailable: Bool
    let statusText: String?
    let availabilityReason: String?

    var id: String { kind.rawValue }
}

struct NewWorkspaceSheet: View {
    let repo: Repo
    let environmentOptions: [WorkspaceEnvironmentSheetOption]
    let isCreateDisabled: Bool
    let onCreate: (String, String, WorkspaceGuestOS?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedEnvironmentID = WorkspaceEnvironmentSheetOption.Kind.local.rawValue
    @State private var isCreating = false

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedOption: WorkspaceEnvironmentSheetOption? {
        environmentOptions.first(where: { $0.id == selectedEnvironmentID })
    }

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

    private var descriptionText: String {
        guard let selectedOption else {
            return "Select an environment."
        }
        return selectedOption.description
    }

    private var selectedAvailabilityReason: String? {
        selectedOption?.availabilityReason
    }

    private var canCreate: Bool {
        isValid
            && !isCreating
            && !isCreateDisabled
            && (selectedOption?.isAvailable ?? false)
    }

    private var preferredInitialEnvironmentID: String? {
        if UIFixtureLumeEnvironment.isEnabled(),
            let macOSVMOption = environmentOptions.first(where: {
                $0.kind == .macOSVM && $0.isAvailable
            })
        {
            return macOSVMOption.id
        }

        if let localOption = environmentOptions.first(where: {
            $0.kind == .local && $0.isAvailable
        }) {
            return localOption.id
        }

        return environmentOptions.first(where: \.isAvailable)?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: iconName)
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

            Divider()

            Form {
                TextField("Workspace Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Environment")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(environmentOptions) { option in
                        EnvironmentSelectionRow(
                            option: option,
                            isSelected: selectedEnvironmentID == option.id
                        ) {
                            guard option.isAvailable else { return }
                            selectedEnvironmentID = option.id
                        }
                    }
                }

                Text(descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let selectedAvailabilityReason,
                    !(selectedOption?.isAvailable ?? true)
                {
                    Text(selectedAvailabilityReason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    isCreating = true
                    guard let selectedOption else { return }
                    onCreate(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        selectedOption.providerID,
                        selectedOption.guestOS
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding()
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if name.isEmpty {
                name = suggestedName
            }
            if let preferredInitialEnvironmentID {
                selectedEnvironmentID = preferredInitialEnvironmentID
            }
        }
    }

    private var iconName: String {
        selectedOption?.iconName ?? "plus.rectangle.on.folder.fill"
    }
}

private struct EnvironmentSelectionRow: View {
    let option: WorkspaceEnvironmentSheetOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(option.isAvailable ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(.body.weight(.semibold))

                        if let statusText = option.statusText {
                            Text(statusText)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(statusColor)
                        } else if !option.isAvailable {
                            Text("Unavailable")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(option.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)

                    if let availabilityReason = option.availabilityReason, !option.isAvailable {
                        Text(availabilityReason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isAvailable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.statusText ?? (option.isAvailable ? "Available" : "Unavailable"))
        .accessibilityHint(option.subtitle)
        .accessibilityIdentifier("workspace-environment-\(option.id)")
    }

    private var statusColor: Color {
        if option.statusText == "Ready" {
            return .secondary
        }
        return .orange
    }
}
