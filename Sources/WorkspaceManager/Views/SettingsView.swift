//
//  SettingsView.swift
//  WorkspaceManager
//
//  App settings including configurable workspace location
//

import SwiftUI
import WorkspaceManagerCore

struct SettingsView: View {
    @AppStorage("workspacesRoot") private var workspacesRootPath: String = ""
    @AppStorage(TerminalMultiplexingMode.storageKey)
    private var terminalMultiplexingModeRawValue: String = TerminalMultiplexingMode.defaultValue.rawValue
    @AppStorage(NotificationConstants.enabledKey)
    private var notificationsEnabled: Bool = NotificationConstants.defaultEnabled

    @State private var showFolderPicker = false
    @ObservedObject private var notificationCoordinator = NotificationCoordinator.shared

    private var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspaces")
            .path
    }

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

                    Picker(
                        "Terminal Session Mode",
                        selection: Binding(
                            get: { terminalMultiplexingMode },
                            set: { terminalMultiplexingMode = $0 }
                        )
                    ) {
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
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable real-time notifications", isOn: $notificationsEnabled)

                    if notificationsEnabled {
                        notificationAuthSection
                    }
                }
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 450)
        .onAppear {
            notificationCoordinator.loadStoredAuth()
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
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

    @ViewBuilder
    private var notificationAuthSection: some View {
        switch notificationCoordinator.authState {
        case .signedIn(let login):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected as \(login)")
                    .font(.callout)
                Spacer()
                Button("Sign Out") {
                    notificationCoordinator.signOut()
                    notificationsEnabled = false
                }
                .font(.callout)
            }

        case .requestingCode, .exchangingToken:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(
                    notificationCoordinator.authState == .requestingCode
                        ? "Starting authentication..." : "Completing authentication..."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

        case .awaitingUserAuth(let code, let url):
            VStack(alignment: .leading, spacing: 6) {
                Text("Enter this code on GitHub:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(code)
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .font(.callout)
                }
                Button("Open GitHub") {
                    if let url = URL(string: url) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.callout)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try Again") {
                    Task { await notificationCoordinator.startDeviceFlow() }
                }
                .font(.callout)
            }

        case .signedOut:
            Button("Sign in with GitHub") {
                Task { await notificationCoordinator.startDeviceFlow() }
            }
        }
    }
}

#Preview {
    SettingsView()
}
