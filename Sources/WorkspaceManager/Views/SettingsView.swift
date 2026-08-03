//
//  SettingsView.swift
//  WorkspaceManager
//
//  App settings including configurable workspace location
//

import AppKit
import SwiftUI
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "SettingsView")

struct SettingsView: View {
    @Environment(\.lumeRuntimeService) private var lumeRuntimeService
    @Environment(\.claudeSettingsInstaller) private var claudeSettingsInstaller
    @EnvironmentObject private var modelStoreStatusController: ModelStoreStatusController
    @ObservedObject private var terminalThemeStore = GhosttyThemeStore.shared

    @AppStorage("workspacesRoot") private var workspacesRootPath: String = ""
    @AppStorage(TerminalMultiplexingMode.storageKey)
    private var terminalMultiplexingModeRawValue: String = TerminalMultiplexingMode.defaultValue.rawValue
    @AppStorage(NotificationConstants.enabledKey)
    private var notificationsEnabled: Bool = NotificationConstants.defaultEnabled
    @AppStorage(ArchivedWorkspaceSettings.purgeDaysKey)
    private var archivedWorkspacePurgeDays: Int = ArchivedWorkspaceSettings.defaultPurgeDays

    @State private var showFolderPicker = false
    @State private var commandLineToolStatus: CommandLineToolStatus?
    @State private var commandLineToolFeedback: String?
    @State private var commandLineToolFeedbackIsError = false
    @ObservedObject private var notificationCoordinator = NotificationCoordinator.shared
    @State private var runtimeSnapshot: LumeRuntimeSnapshot?
    @State private var runtimeActionLabel: String?
    @State private var runtimeErrorMessage: String?
    @State private var isRunningRuntimeAction = false

    private let commandLineToolService: CommandLineToolService
    private let softwareUpdateController: SoftwareUpdateController?

    init(
        commandLineToolService: CommandLineToolService = CommandLineToolService(),
        softwareUpdateController: SoftwareUpdateController? = nil
    ) {
        self.commandLineToolService = commandLineToolService
        self.softwareUpdateController = softwareUpdateController
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
                    Text("WorkSpaces Location")
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

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Stepper(
                        "Delete archived workspaces after \(archivedWorkspacePurgeDays) days",
                        value: $archivedWorkspacePurgeDays,
                        in: 1...365
                    )
                    .font(.headline)

                    Text(
                        "Archiving moves a workspace into a hidden .archived folder. It is permanently deleted after this delay."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("General")
            }

            Section {
                if let softwareUpdateController {
                    SoftwareUpdateSettingsView(updater: softwareUpdateController.updater)
                } else {
                    Text("Update settings are unavailable in this preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Use WorkSpaces from Terminal")
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
                            Text("scripts/setup")
                                .font(.system(.body, design: .monospaced))
                            Text("— Runs after workspace is created")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "play.circle")
                                .foregroundStyle(.green)
                        }

                        Label {
                            Text("scripts/stop, scripts/archive")
                                .font(.system(.body, design: .monospaced))
                            Text("— Runs before archive or delete")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)

                    Text("WorkSpaces also supports legacy setup.sh and archive.sh hooks.")
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

                    Divider()
                        .padding(.vertical, 4)

                    TerminalThemeSettingsSection(store: terminalThemeStore)
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
                AgentsSettingsView(installer: claudeSettingsInstaller)
            } header: {
                Text("Agents")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Lume Runtime")
                        .font(.headline)

                    runtimeRow(
                        label: "Status",
                        value: runtimeSnapshot?.state.label ?? "Checking..."
                    )
                    runtimeRow(
                        label: "CLI",
                        value: runtimeSnapshot?.executablePath ?? "Not installed"
                    )
                    runtimeRow(
                        label: "Daemon",
                        value: daemonStatusText
                    )
                    runtimeRow(
                        label: "Host Profile",
                        value: runtimeSnapshot?.hostProfile?.displayName ?? "Unavailable"
                    )
                    runtimeRow(
                        label: "Default macOS VM",
                        value: runtimeSnapshot?.defaultMacOSImage?.profileDisplayName
                            ?? runtimeSnapshot?.defaultMacOSImageError
                            ?? "Unavailable"
                    )
                    runtimeRow(
                        label: "Base macOS VM",
                        value: runtimeSnapshot?.baseVM?.profile.displayName ?? "Unavailable"
                    )
                    runtimeRow(
                        label: "Base VM Status",
                        value: runtimeSnapshot?.baseVM?.status.label ?? "Unavailable"
                    )
                    runtimeRow(
                        label: "Base VM Name",
                        value: runtimeSnapshot?.baseVM?.profile.vmName ?? "Unavailable"
                    )
                    runtimeRow(
                        label: "Base VM Source",
                        value: runtimeSnapshot?.baseVM?.sourceKind?.label
                            ?? runtimeSnapshot?.baseVM?.profile.preferredSourceKind.label
                            ?? "Unavailable"
                    )
                    runtimeRow(
                        label: "LaunchAgent",
                        value: runtimeSnapshot?.launchAgentPath ?? "Unavailable"
                    )

                    if let reason = runtimeSnapshot?.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let baseReason = runtimeSnapshot?.baseVM?.reason {
                        Text(baseReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let runtimeActionLabel {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(runtimeActionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Verify") {
                            runVerify()
                        }
                        .disabled(isRunningRuntimeAction)

                        Button("Repair") {
                            runRepair()
                        }
                        .disabled(isRunningRuntimeAction)

                        Button("Reinstall") {
                            runReinstall()
                        }
                        .disabled(isRunningRuntimeAction)
                    }

                    HStack(spacing: 10) {
                        Button("Prepare Base VM") {
                            runPrepareBaseVM()
                        }
                        .disabled(
                            isRunningRuntimeAction
                                || runtimeSnapshot?.state == .unsupportedHost
                        )

                        Button("Delete Base VM") {
                            runDeleteBaseVM()
                        }
                        .disabled(
                            isRunningRuntimeAction
                                || runtimeSnapshot?.baseVM == nil
                        )

                        Button("Refresh") {
                            Task { @MainActor in
                                await refreshRuntimeSnapshot()
                            }
                        }
                        .disabled(isRunningRuntimeAction)
                    }

                    HStack(spacing: 10) {
                        Button("Open Info Log") {
                            openLog(at: runtimeSnapshot?.infoLogPath)
                        }
                        .disabled(runtimeSnapshot == nil)

                        Button("Open Error Log") {
                            openLog(at: runtimeSnapshot?.errorLogPath)
                        }
                        .disabled(runtimeSnapshot == nil)
                    }
                }
            } header: {
                Text("VM Runtime")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Model Store")
                        .font(.headline)

                    runtimeRow(
                        label: "Active Mode",
                        value: modelStoreStatusController.mode.label
                    )

                    runtimeRow(
                        label: "Store Path",
                        value: modelStoreStatusController.mode.path ?? "In-memory only"
                    )

                    if modelStoreStatusController.bootstrapErrors.isEmpty {
                        Text("No bootstrap fallbacks were required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bootstrap Failures")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(
                                Array(modelStoreStatusController.bootstrapErrors.enumerated()),
                                id: \.offset
                            ) { _, error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } header: {
                Text("Persistence")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Diagnostic Report")
                        .font(.headline)

                    Text(
                        "Export a report with system info, recent app logs, and startup performance data for troubleshooting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Export Diagnostic Report...") {
                        Task {
                            await DiagnosticReportExporter.exportWithSavePanel()
                        }
                    }
                }
            } header: {
                Text("Diagnostics")
            }

            Section {
                ExperimentalFeaturesSettingsView()
            } header: {
                Text("Experimental Features")
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
        .frame(width: 560, height: 700)
        .accessibilityIdentifier("settings.root")
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
                log.error("Folder picker error: \(error, privacy: .public)")
            }
        }
        .task {
            await refreshRuntimeSnapshot()
        }
        .alert(
            "Could Not Update VM Runtime",
            isPresented: Binding(
                get: { runtimeErrorMessage != nil },
                set: { if !$0 { runtimeErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                runtimeErrorMessage = nil
            }
        } message: {
            Text(runtimeErrorMessage ?? "Unknown error.")
        }
    }

    private var daemonStatusText: String {
        guard let runtimeSnapshot else { return "Checking..." }
        return runtimeSnapshot.daemonReachable ? "Reachable" : "Unavailable"
    }

    private func runtimeRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @MainActor
    private func refreshRuntimeSnapshot() async {
        runtimeSnapshot = await lumeRuntimeService.snapshot()
    }

    private func runVerify() {
        Task { @MainActor in
            await runRuntimeAction(label: "Verifying Lume runtime...") {
                try await lumeRuntimeService.verifyInstallation(progress: nil)
            }
        }
    }

    private func runRepair() {
        Task { @MainActor in
            await runRuntimeAction(label: "Repairing Lume runtime...") {
                try await lumeRuntimeService.repairInstallation(progress: nil)
            }
        }
    }

    private func runReinstall() {
        Task { @MainActor in
            await runRuntimeAction(label: "Reinstalling Lume runtime...") {
                let snapshot = await lumeRuntimeService.snapshot()
                switch snapshot.state {
                case .setupRequired:
                    return try await lumeRuntimeService.installIfNeeded(progress: nil)
                case .unsupportedHost:
                    throw LumeRuntimeError.unsupportedHost(
                        snapshot.reason ?? "Lume is unsupported on this Mac."
                    )
                default:
                    return try await lumeRuntimeService.repairInstallation(progress: nil)
                }
            }
        }
    }

    private func runPrepareBaseVM() {
        Task { @MainActor in
            await runRuntimeAction(label: "Preparing base macOS VM...") {
                _ = try await lumeRuntimeService.ensureBaseVMReady(progress: nil)
                return await lumeRuntimeService.snapshot()
            }
        }
    }

    private func runDeleteBaseVM() {
        Task { @MainActor in
            await runRuntimeAction(label: "Deleting base macOS VM...") {
                try await lumeRuntimeService.deleteBaseVM()
            }
        }
    }

    @MainActor
    private func runRuntimeAction(
        label: String,
        operation: @escaping () async throws -> LumeRuntimeSnapshot
    ) async {
        isRunningRuntimeAction = true
        runtimeActionLabel = label
        defer {
            isRunningRuntimeAction = false
            runtimeActionLabel = nil
        }

        do {
            runtimeSnapshot = try await operation()
        } catch {
            runtimeErrorMessage = error.localizedDescription
            runtimeSnapshot = await lumeRuntimeService.snapshot()
        }
    }

    private func openLog(at path: String?) {
        guard let path, !path.isEmpty else {
            runtimeErrorMessage = "No log path is available."
            return
        }

        let logURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            runtimeErrorMessage = "The log file does not exist yet at \(path)."
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
            return "The `workspaces` command is ready to open WorkSpaces from Terminal."
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
