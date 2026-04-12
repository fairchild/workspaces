//
//  NewWebSourceSheet.swift
//  WorkspaceManager
//
//  Sheet for adding a URL source.
//

import SwiftUI

struct NewWebSourceSheet: View {
    let target: WebSourceCreationTarget
    let onCreate: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var additionalAllowedDomains = ""
    @State private var isCreating = false

    private var isValid: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: target.iconName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                Text(target.title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(target.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            Form {
                TextField("Name (Optional)", text: $name)
                    .textFieldStyle(.roundedBorder)

                TextField("URL (e.g. docs.example.com)", text: $url)
                    .textFieldStyle(.roundedBorder)

                TextField(
                    "Additional Allowlisted Domains (Optional, comma/newline separated)",
                    text: $additionalAllowedDomains,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

                Text("Only http/https URLs are supported. Navigation is restricted to the configured domain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Use *.example.com to allow that domain and all subdomains.")
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

                Button(target.buttonTitle) {
                    isCreating = true
                    onCreate(
                        url.trimmingCharacters(in: .whitespacesAndNewlines),
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        additionalAllowedDomains.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding()
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
