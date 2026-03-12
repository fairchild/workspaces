//
//  SettingsView.swift
//  WorkspaceManager
//
//  App settings including configurable workspace location
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

struct SettingsView: View {
    @AppStorage("workspacesRoot") private var workspacesRootPath: String = ""
    @AppStorage(TerminalMultiplexingMode.storageKey)
    private var terminalMultiplexingModeRawValue: String = TerminalMultiplexingMode.defaultValue.rawValue
    @AppStorage(NotificationConstants.enabledKey)
    private var notificationsEnabled: Bool = NotificationConstants.defaultEnabled

    @State private var showFolderPicker = false
    @State private var commandLineToolStatus: CommandLineToolStatus?
    @State private var commandLineToolFeedback: String?
    @State private var commandLineToolFeedbackIsError = false
    @ObservedObject private var notificationCoordinator = NotificationCoordinator.shared

    private let commandLineToolService: CommandLineToolService

    init(commandLineToolService: CommandLineToolService = CommandLineToolService()) {
        self.commandLineToolService = commandLineToolService
        _commandLineToolStatus = State(initialValue: nil)
    }

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
                VStack(alignment: .leading, spacing: 10) {
                    Text("Use Workspaces from Terminal")
                        .font(.headline)

                    if let commandLineToolStatus {
                        HStack(spacing: 8) {
                            Image(systemName: commandLineToolStatusSymbolName(for: commandLineToolStatus))
                                .foregroundStyle(commandLineToolStatusColor(for: commandLineToolStatus))
                            Text(commandLineToolStatusTitle(for: commandLineToolStatus))
                                .font(.callout.weight(.medium))
                        }

                        if let commandPath = commandLineToolStatus.commandPath {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Command Path")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(commandPath)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(.rect(cornerRadius: 6))
                        }

                        Text(commandLineToolStatusDetail(for: commandLineToolStatus))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            if let primaryAction = commandLineToolStatus.primaryAction {
                                Button(primaryAction.title) {
                                    installCommandLineTool()
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if commandLineToolStatus.setupCommand != nil {
                                Button("Copy Setup Command") {
                                    copyCommandLineToolSetupCommand()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking installation status…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let commandLineToolFeedback {
                        Text(commandLineToolFeedback)
                            .font(.caption)
                            .foregroundStyle(commandLineToolFeedbackIsError ? .red : .green)
                    }
                }
            } header: {
                Text("Command Line Tool")
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

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Self.versionString)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
        .onAppear {
            refreshCommandLineToolStatus()
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

    private func commandLineToolStatusTitle(for status: CommandLineToolStatus) -> String {
        switch status.availability {
        case .installed:
            return "Installed"
        case .notInstalled:
            return "Not Installed"
        case .unavailable:
            return "Unavailable"
        }
    }

    private func commandLineToolStatusSymbolName(for status: CommandLineToolStatus) -> String {
        switch status.availability {
        case .installed:
            return "checkmark.circle.fill"
        case .notInstalled:
            return "arrow.down.circle"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    private func commandLineToolStatusColor(for status: CommandLineToolStatus) -> Color {
        switch status.availability {
        case .installed:
            return .green
        case .notInstalled:
            return .orange
        case .unavailable:
            return .red
        }
    }

    private func commandLineToolStatusDetail(for status: CommandLineToolStatus) -> String {
        let commandPath = status.commandPath ?? "the selected install location"

        switch status.reason {
        case .active:
            return "The `workspaces` command is ready to open Workspaces from Terminal."
        case .missing:
            return "Install the `workspaces` command at \(commandPath) so `workspaces .` opens the current folder."
        case .missingFromPath:
            return
                "The launcher is already linked at \(commandPath), but Terminal may not see that directory yet. Use the copied setup command to prepend it to PATH."
        case .brokenSymlink:
            return "The command link exists at \(commandPath), but it no longer points to this app."
        case .differentTarget(let existingTargetPath):
            if let existingTargetPath {
                return "The command at \(commandPath) points to \(existingTargetPath) instead of this app."
            }
            return "The command at \(commandPath) points somewhere else and should be repaired."
        case .conflictingFile:
            return
                "A different file already exists at \(commandPath). Move or rename it before installing this launcher."
        case .shadowedByOtherCommand(let path):
            return
                "Another `workspaces` command at \(path) is taking precedence in PATH. Install here, then use the copied setup command to make this location win."
        case .missingBundledCommand:
            return "This app build does not include the bundled `workspaces` launcher."
        case .noWritableInstallLocation:
            return "No writable install location was found for the `workspaces` command."
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

    private func refreshCommandLineToolStatus() {
        let service = commandLineToolService
        DispatchQueue.global(qos: .userInitiated).async {
            let status = service.status()
            DispatchQueue.main.async {
                commandLineToolStatus = status
            }
        }
    }

    private func installCommandLineTool() {
        do {
            let status = try commandLineToolService.installOrRepair()
            commandLineToolStatus = status
            commandLineToolFeedbackIsError = false
            if let commandPath = status.commandPath {
                commandLineToolFeedback = "Linked `workspaces` at \(commandPath)."
            } else {
                commandLineToolFeedback = "Updated the `workspaces` command."
            }
        } catch {
            commandLineToolFeedbackIsError = true
            commandLineToolFeedback = error.localizedDescription
            refreshCommandLineToolStatus()
        }
    }

    private func copyCommandLineToolSetupCommand() {
        guard let setupCommand = commandLineToolStatus?.setupCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupCommand, forType: .string)
        commandLineToolFeedbackIsError = false
        commandLineToolFeedback = "Copied the setup command."
    }

    private static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
}
