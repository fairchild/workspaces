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
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.folder.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

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

                Text("A copy of the repository will be created in a new directory.")
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
                    onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines))
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
