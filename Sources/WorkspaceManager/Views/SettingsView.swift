//
//  SettingsView.swift
//  WorkspaceManager
//
//  App settings including configurable workspace location
//

import SwiftUI

struct SettingsView: View {
    // Workspace root path stored in UserDefaults
    @AppStorage("workspacesRoot") private var workspacesRootPath: String = ""
    @AppStorage(TerminalMultiplexingMode.storageKey)
    private var terminalMultiplexingModeRawValue: String = TerminalMultiplexingMode.defaultValue.rawValue

    // File picker state
    @State private var showFolderPicker = false

    // Default path for display
    private var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspaces")
            .path
    }

    // Display path (shows default if custom not set)
    private var displayPath: String {
        workspacesRootPath.isEmpty ? defaultPath : workspacesRootPath
    }

    private var terminalMultiplexingMode: TerminalMultiplexingMode {
        get { TerminalMultiplexingMode(rawValue: terminalMultiplexingModeRawValue) ?? .defaultValue }
        nonmutating set { terminalMultiplexingModeRawValue = newValue.rawValue }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Workspaces Location")
                        .font(.headline)

                    HStack {
                        Text(displayPath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Choose...") {
                            showFolderPicker = true
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Text("Where new workspaces are created.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if !workspacesRootPath.isEmpty {
                            Button("Reset to Default") {
                                workspacesRootPath = ""
                            }
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Text("General")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lifecycle Scripts")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text("setup.sh")
                                .font(.system(.body, design: .monospaced))
                            Text("— Runs after workspace is created")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "play.circle")
                                .foregroundStyle(.green)
                        }

                        Label {
                            Text("archive.sh")
                                .font(.system(.body, design: .monospaced))
                            Text("— Runs when workspace is closed")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)

                    Text("Add these scripts to your repository to automate workspace setup and cleanup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Automation")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Terminal Session Mode")
                        .font(.headline)

                    Picker("Terminal Session Mode", selection: Binding(
                        get: { terminalMultiplexingMode },
                        set: { terminalMultiplexingMode = $0 }
                    )) {
                        ForEach(TerminalMultiplexingMode.allCases) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(terminalMultiplexingMode.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Terminal")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 350)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Get security-scoped access
                    if url.startAccessingSecurityScopedResource() {
                        workspacesRootPath = url.path
                        url.stopAccessingSecurityScopedResource()
                    } else {
                        workspacesRootPath = url.path
                    }
                }
            case .failure(let error):
                print("Folder picker error: \(error)")
            }
        }
    }
}

#Preview {
    SettingsView()
}
