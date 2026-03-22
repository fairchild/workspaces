//
//  NewWorkspaceSheet.swift
//  WorkspaceManager
//
//  Sheet for creating a new workspace from a repository
//

import SwiftUI
import WorkspaceManagerCore

/// Semantic severity for the status badge shown in an environment selection row.
enum EnvironmentStatusSeverity {
    /// Best-state indicator — rendered in accent color (green). Use for "Fast clone ready".
    case good
    /// Informational or in-progress — rendered in secondary. Use for "Installing", "Verifying",
    /// "Preparing base", or any status that is transient and expected.
    case neutral
    /// Needs attention but not blocking selection — rendered in orange. Use for
    /// "Setup required" or "Repair base VM".
    case warning
    /// Blocking failure — rendered in red. Use for "Repair required" (broken Lume runtime).
    case error
}

struct WorkspaceEnvironmentSheetOption: Identifiable {
    let title: String
    let subtitle: String
    let description: String
    let iconName: String
    let providerID: String
    let guestOS: WorkspaceGuestOS?
    let isAvailable: Bool
    let isLoading: Bool
    let statusText: String?
    let statusSeverity: EnvironmentStatusSeverity?
    let availabilityReason: String?

    var id: String {
        Self.selectionID(providerID: providerID, guestOS: guestOS)
    }

    static func selectionID(providerID: String, guestOS: WorkspaceGuestOS?) -> String {
        if let guestOS {
            return "\(providerID):\(guestOS.rawValue)"
        }
        return providerID
    }
}

struct NewWorkspaceSheet: View {
    let repo: Repo
    let environmentOptions: [WorkspaceEnvironmentSheetOption]
    let isPreparingEnvironmentOptions: Bool
    let isCreateDisabled: Bool
    let onCreate: (String, WorkspaceNameSource, String, WorkspaceGuestOS?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedEnvironmentID = WorkspaceEnvironmentSheetOption.selectionID(
        providerID: LocalWorkspaceProvider.identifier,
        guestOS: nil
    )
    @State private var generatedName = ""
    @State private var isCreating = false
    @State private var nameSource: WorkspaceNameSource = .generatedDefault

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedOption: WorkspaceEnvironmentSheetOption? {
        environmentOptions.first(where: { $0.id == selectedEnvironmentID })
    }

    private var sanitizedWorkspaceNameComponent: String {
        WorkspaceService.sanitizeWorkspaceNameComponent(trimmedName)
    }

    private var requestValidationMessage: String? {
        guard !trimmedName.isEmpty else {
            return "Enter a workspace name."
        }
        guard WorkspaceService.isValidWorkspaceNameComponent(sanitizedWorkspaceNameComponent) else {
            return "Enter a valid workspace name."
        }
        return nil
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
        requestValidationMessage == nil
            && !isCreating
            && !isCreateDisabled
            && (selectedOption?.isAvailable ?? false)
    }

    private var preferredInitialEnvironmentID: String? {
        Self.preferredInitialEnvironmentID(
            for: environmentOptions,
            fixtureEnabled: UIFixtureLumeEnvironment.isEnabled()
        )
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

            if isPreparingEnvironmentOptions {
                preparationBanner
                Divider()
            }

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

                if let requestValidationMessage {
                    Text(requestValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
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
                        trimmedName,
                        nameSource,
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
            configureInitialNameIfNeeded()
            if let preferredInitialEnvironmentID {
                selectedEnvironmentID = preferredInitialEnvironmentID
            }
            InvestigationDiagnostics.emitSheet(
                phase: "sheet_on_appear",
                fields: [
                    "repo_id": repo.id.uuidString,
                    "option_count": "\(environmentOptions.count)",
                    "selected_environment": selectedEnvironmentID,
                ]
            )
        }
        .onChange(of: name) { _, newValue in
            updateNameSource(for: newValue)
        }
    }

    private var preparationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("Checking workspace environments...")
                    .font(.callout.weight(.semibold))

                Text(
                    "Provider availability and VM runtime details are still loading. "
                        + "You can keep typing while the options update."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.06))
    }

    private var iconName: String {
        selectedOption?.iconName ?? "plus.rectangle.on.folder.fill"
    }

    private func configureInitialNameIfNeeded() {
        guard generatedName.isEmpty else { return }

        generatedName = WorkspaceNameGenerator.generateDefaultName(
            occupiedSanitizedNames: WorkspaceNameGenerator.sanitizedNameSet(
                from: repo.workspaces.map(\.name)
            )
        )

        if name.isEmpty {
            name = generatedName
        }

        updateNameSource(for: name)
    }

    private func updateNameSource(for value: String) {
        nameSource =
            value.trimmingCharacters(in: .whitespacesAndNewlines) == generatedName
            ? .generatedDefault
            : .manual
    }

    static func preferredInitialEnvironmentID(
        for environmentOptions: [WorkspaceEnvironmentSheetOption],
        fixtureEnabled: Bool
    ) -> String? {
        if fixtureEnabled,
            let macOSVMOption = environmentOptions.first(where: {
                $0.isAvailable
                    && $0.providerID == LumeWorkspaceProvider.identifier
                    && $0.guestOS == .macOS
            })
        {
            return macOSVMOption.id
        }

        if let localOption = environmentOptions.first(where: {
            $0.isAvailable
                && $0.providerID == LocalWorkspaceProvider.identifier
                && $0.guestOS == nil
        }) {
            return localOption.id
        }

        return environmentOptions.first(where: \.isAvailable)?.id
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

                        if option.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        if let statusText = option.statusText {
                            Text(statusText)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(statusColor)
                        } else if !option.isAvailable && !option.isLoading {
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
        switch option.statusSeverity {
        case .good: return .accentColor
        case .neutral: return .secondary
        case .warning: return .orange
        case .error: return .red
        case nil: return .secondary
        }
    }
}
