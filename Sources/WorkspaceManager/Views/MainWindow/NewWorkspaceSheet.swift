//
//  NewWorkspaceSheet.swift
//  WorkspaceManager
//
//  Sheet for creating a new workspace from a repository
//

import SwiftUI
import WorkspaceManagerCore

enum WorkspaceBackendChoice: String, CaseIterable, Identifiable {
    case local
    case remoteVM

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "Local"
        case .remoteVM: return "Remote VM"
        }
    }

    var icon: String {
        switch self {
        case .local: return "laptopcomputer"
        case .remoteVM: return "cloud"
        }
    }
}

struct NewWorkspaceSheet: View {
    let repo: Repo
    let isDaytonaAvailable: Bool
    let onCreate: (String, WorkspaceBackendChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var backend: WorkspaceBackendChoice = .local
    @State private var isCreating = false

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        switch backend {
        case .local:
            return "A copy of the repository will be created in a new directory."
        case .remoteVM:
            return "A remote Linux sandbox will be created via Daytona."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: backend == .remoteVM ? "cloud.fill" : "plus.rectangle.on.folder.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(backend == .remoteVM ? .blue : .blue)

                Text("New Workspace")
                    .font(.title2)
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

                if isDaytonaAvailable {
                    Picker("Environment", selection: $backend) {
                        ForEach(WorkspaceBackendChoice.allCases) { choice in
                            Label(choice.label, systemImage: choice.icon)
                                .tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text(descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), backend)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding()
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if name.isEmpty {
                name = suggestedName
            }
        }
    }
}
