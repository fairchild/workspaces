//
//  HostLumeSmokeAutomation.swift
//  WorkspaceManager
//
//  Dev-only real-host automation for end-to-end Lume macOS VM smoke tests.
//

import Foundation
import WorkspaceManagerCore

struct HostLumeSmokeAutomationConfiguration: Equatable, Sendable {
    static let modeEnvironmentKey = "WORKSPACES_AUTOMATION_MODE"
    static let repoPathEnvironmentKey = "WORKSPACES_AUTOMATION_REPO_PATH"
    static let workspaceNameEnvironmentKey = "WORKSPACES_AUTOMATION_WORKSPACE_NAME"
    static let eventsPathEnvironmentKey = "WORKSPACES_AUTOMATION_EVENTS_PATH"

    let repoURL: URL
    let workspaceName: String
    let eventsURL: URL

    static func from(environment: [String: String]) -> HostLumeSmokeAutomationConfiguration? {
        guard
            environment[modeEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "host-lume-macos-smoke"
        else {
            return nil
        }

        guard
            let repoPath = environment[repoPathEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !repoPath.isEmpty,
            let workspaceName = environment[workspaceNameEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !workspaceName.isEmpty,
            let eventsPath = environment[eventsPathEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !eventsPath.isEmpty
        else {
            return nil
        }

        return HostLumeSmokeAutomationConfiguration(
            repoURL: URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath),
            workspaceName: workspaceName,
            eventsURL: URL(fileURLWithPath: (eventsPath as NSString).expandingTildeInPath)
        )
    }
}

struct HostLumeSmokeLumeMetadataRecord: Codable, Sendable, Equatable {
    let vmName: String
    let storagePath: String?
    let guestOS: String
    let sharedHostPath: String
    let desktopSupported: Bool
    let profileKey: String?
    let profileDisplayName: String?
    let imageReference: String?
    let baseVMName: String?
    let baseSourceKind: String?

    init(metadata: LumeWorkspaceMetadata) {
        vmName = metadata.vmName
        storagePath = metadata.storagePath
        guestOS = metadata.guestOS.rawValue
        sharedHostPath = metadata.sharedHostPath
        desktopSupported = metadata.desktopSupported
        profileKey = metadata.profileKey
        profileDisplayName = metadata.profileDisplayName
        imageReference = metadata.imageReference
        baseVMName = metadata.baseVMName
        baseSourceKind = metadata.baseSourceKind?.rawValue
    }
}

struct HostLumeSmokeWorkspaceRecord: Codable, Sendable, Equatable {
    let workspaceName: String
    let workspacePath: String
    let providerID: String
    let remoteID: String?
    let status: String
    let gitBranch: String?
    let lumeMetadata: HostLumeSmokeLumeMetadataRecord?

    init(result: WorkspaceProviderCreationResult) {
        workspaceName = result.name
        workspacePath = result.path.path
        providerID = result.backendIdentifier
        remoteID = result.remoteId
        status = result.status.rawValue
        gitBranch = result.gitBranch
        lumeMetadata = Self.decodeLumeMetadata(from: result.backendMetadataRaw)
    }

    @MainActor
    init(workspace: Workspace) {
        workspaceName = workspace.name
        workspacePath = workspace.path
        providerID = workspace.backendIdentifier
        remoteID = workspace.remoteId
        status = workspace.status.rawValue
        gitBranch = workspace.gitBranch
        lumeMetadata = workspace.decodeBackendMetadata(LumeWorkspaceMetadata.self).map {
            HostLumeSmokeLumeMetadataRecord(metadata: $0)
        }
    }

    private static func decodeLumeMetadata(from rawValue: String) -> HostLumeSmokeLumeMetadataRecord? {
        guard !rawValue.isEmpty, let data = rawValue.data(using: .utf8) else {
            return nil
        }

        return (try? JSONDecoder().decode(LumeWorkspaceMetadata.self, from: data)).map {
            HostLumeSmokeLumeMetadataRecord(metadata: $0)
        }
    }
}

private struct HostLumeSmokeEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case launchReady = "launch_ready"
        case repoReady = "repo_ready"
        case setupConfirmationPresented = "setup_confirmation_presented"
        case setupStepChanged = "setup_step_changed"
        case workspaceCreationStarted = "workspace_creation_started"
        case workspacePhaseChanged = "workspace_phase_changed"
        case workspacePersisted = "workspace_persisted"
        case workspaceActive = "workspace_active"
        case failure
    }

    let type: Kind
    let timestamp: String
    let repoName: String?
    let repoPath: String?
    let workspaceName: String?
    let workspacePath: String?
    let providerID: String?
    let remoteID: String?
    let workspaceStatus: String?
    let runtimeState: String?
    let setupStep: String?
    let phaseMessage: String?
    let message: String?
    let recoveryHints: [String]?
    let lumeMetadata: HostLumeSmokeLumeMetadataRecord?
}

actor HostLumeSmokeEventWriter {
    private let eventsURL: URL
    private let encoder = JSONEncoder()
    private let fileManager = FileManager.default

    init(eventsURL: URL) {
        self.eventsURL = eventsURL
        encoder.outputFormatting = [.sortedKeys]

        let directoryURL = eventsURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if fileManager.fileExists(atPath: eventsURL.path) {
            try? fileManager.removeItem(at: eventsURL)
        }
        _ = fileManager.createFile(atPath: eventsURL.path, contents: Data())
    }

    fileprivate func emit(_ event: HostLumeSmokeEvent) async {
        guard
            let encoded = try? encoder.encode(event),
            let handle = try? FileHandle(forWritingTo: eventsURL)
        else {
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            NSLog("[HostLumeSmokeAutomation] Failed to write event: %@", error.localizedDescription)
        }
    }
}

@MainActor
final class HostLumeSmokeAutomationController: ObservableObject {
    let configuration: HostLumeSmokeAutomationConfiguration?

    private let writer: HostLumeSmokeEventWriter?
    private var emittedLaunchReady = false
    private var emittedRepoPath: String?
    private var hasStartedWorkspaceCreation = false
    private var lastSetupConfirmationSignature: String?
    private var lastSetupStepRawValue: String?
    private var lastPhaseMessage: String?
    private var lastPersistedWorkspace: HostLumeSmokeWorkspaceRecord?
    private var lastActiveWorkspace: HostLumeSmokeWorkspaceRecord?
    private var lastFailureSignature: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configuration = HostLumeSmokeAutomationConfiguration.from(environment: environment)
        self.configuration = configuration
        self.writer = configuration.map { HostLumeSmokeEventWriter(eventsURL: $0.eventsURL) }
    }

    var isEnabled: Bool {
        configuration != nil && writer != nil
    }

    var targetRepoURL: URL? {
        configuration?.repoURL
    }

    var targetWorkspaceName: String? {
        configuration?.workspaceName
    }

    func matchingRepo(in repos: [Repo], normalizePath: (URL) -> String) -> Repo? {
        guard let targetRepoURL else { return nil }
        let targetPath = normalizePath(targetRepoURL)
        return repos.first(where: { normalizePath($0.localURL) == targetPath })
    }

    func noteLaunchReady() async {
        guard isEnabled, !emittedLaunchReady else { return }
        emittedLaunchReady = true
        await emit(
            .init(
                type: .launchReady,
                timestamp: Self.timestamp(),
                repoName: nil,
                repoPath: targetRepoURL?.path,
                workspaceName: targetWorkspaceName,
                workspacePath: nil,
                providerID: nil,
                remoteID: nil,
                workspaceStatus: nil,
                runtimeState: nil,
                setupStep: nil,
                phaseMessage: nil,
                message: nil,
                recoveryHints: nil,
                lumeMetadata: nil
            )
        )
    }

    func noteRepoReady(_ repo: Repo) async {
        guard isEnabled else { return }
        let normalizedPath = repo.localURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard emittedRepoPath != normalizedPath else { return }
        emittedRepoPath = normalizedPath

        await emit(
            .init(
                type: .repoReady,
                timestamp: Self.timestamp(),
                repoName: repo.name,
                repoPath: normalizedPath,
                workspaceName: targetWorkspaceName,
                workspacePath: nil,
                providerID: nil,
                remoteID: nil,
                workspaceStatus: nil,
                runtimeState: nil,
                setupStep: nil,
                phaseMessage: nil,
                message: nil,
                recoveryHints: nil,
                lumeMetadata: nil
            )
        )
    }

    func shouldStartWorkspaceCreation() -> Bool {
        guard isEnabled, !hasStartedWorkspaceCreation else { return false }
        hasStartedWorkspaceCreation = true
        return true
    }

    func noteWorkspaceCreationStarted(repo: Repo) async {
        guard isEnabled else { return }
        await emit(
            .init(
                type: .workspaceCreationStarted,
                timestamp: Self.timestamp(),
                repoName: repo.name,
                repoPath: repo.localURL.standardizedFileURL.resolvingSymlinksInPath().path,
                workspaceName: targetWorkspaceName,
                workspacePath: nil,
                providerID: LumeWorkspaceProvider.identifier,
                remoteID: nil,
                workspaceStatus: WorkspaceStatus.provisioning.rawValue,
                runtimeState: nil,
                setupStep: nil,
                phaseMessage: "Requested macOS VM workspace creation.",
                message: nil,
                recoveryHints: nil,
                lumeMetadata: nil
            )
        )
    }

    func noteSetupConfirmationPresented(_ request: WorkspaceProviderSetupConfirmationRequest) async {
        guard isEnabled else { return }
        guard request.providerID == LumeWorkspaceProvider.identifier else { return }
        let signature = "\(request.state ?? "unknown")|\(request.action.summary)"
        guard signature != lastSetupConfirmationSignature else { return }
        lastSetupConfirmationSignature = signature

        await emit(
            .init(
                type: .setupConfirmationPresented,
                timestamp: Self.timestamp(),
                repoName: nil,
                repoPath: targetRepoURL?.path,
                workspaceName: targetWorkspaceName,
                workspacePath: nil,
                providerID: LumeWorkspaceProvider.identifier,
                remoteID: nil,
                workspaceStatus: nil,
                runtimeState: request.state,
                setupStep: nil,
                phaseMessage: nil,
                message: request.title,
                recoveryHints: nil,
                lumeMetadata: nil
            )
        )
    }

    func noteSetupStepChanged(_ presentation: WorkspaceProviderSetupProgressPresentation) async {
        guard isEnabled, presentation.providerID == LumeWorkspaceProvider.identifier else { return }
        let step = presentation.step
        guard step.id != lastSetupStepRawValue else { return }
        lastSetupStepRawValue = step.id

        await emit(
            .init(
                type: .setupStepChanged,
                timestamp: Self.timestamp(),
                repoName: nil,
                repoPath: targetRepoURL?.path,
                workspaceName: targetWorkspaceName,
                workspacePath: nil,
                providerID: LumeWorkspaceProvider.identifier,
                remoteID: nil,
                workspaceStatus: nil,
                runtimeState: nil,
                setupStep: step.id,
                phaseMessage: step.label,
                message: nil,
                recoveryHints: nil,
                lumeMetadata: nil
            )
        )
    }

    func noteWorkspacePhaseChanged(message: String) async {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !trimmedMessage.isEmpty, trimmedMessage != lastPhaseMessage else { return }
        lastPhaseMessage = trimmedMessage

        await emit(
            .init(
                type: .workspacePhaseChanged,
                timestamp: Self.timestamp(),
                repoName: nil,
                repoPath: targetRepoURL?.path,
                workspaceName: targetWorkspaceName,
                workspacePath: nil,
                providerID: LumeWorkspaceProvider.identifier,
                remoteID: nil,
                workspaceStatus: WorkspaceStatus.provisioning.rawValue,
                runtimeState: nil,
                setupStep: nil,
                phaseMessage: trimmedMessage,
                message: nil,
                recoveryHints: nil,
                lumeMetadata: nil
            )
        )
    }

    func noteWorkspacePersisted(_ record: HostLumeSmokeWorkspaceRecord) async {
        guard isEnabled, record != lastPersistedWorkspace else { return }
        lastPersistedWorkspace = record

        await emit(event(for: .workspacePersisted, workspace: record))
    }

    func noteWorkspaceActive(_ record: HostLumeSmokeWorkspaceRecord) async {
        guard isEnabled, record != lastActiveWorkspace else { return }
        lastActiveWorkspace = record

        await emit(event(for: .workspaceActive, workspace: record))
    }

    func noteFailure(message: String, recoveryHints: [String] = []) async {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !trimmedMessage.isEmpty else { return }

        let signature = "\(trimmedMessage)|\(recoveryHints.joined(separator: ","))"
        guard signature != lastFailureSignature else { return }
        lastFailureSignature = signature

        await emit(
            .init(
                type: .failure,
                timestamp: Self.timestamp(),
                repoName: nil,
                repoPath: targetRepoURL?.path,
                workspaceName: targetWorkspaceName,
                workspacePath: nil,
                providerID: nil,
                remoteID: nil,
                workspaceStatus: nil,
                runtimeState: nil,
                setupStep: nil,
                phaseMessage: nil,
                message: trimmedMessage,
                recoveryHints: recoveryHints.isEmpty ? nil : recoveryHints,
                lumeMetadata: lastPersistedWorkspace?.lumeMetadata ?? lastActiveWorkspace?.lumeMetadata
            )
        )
    }

    private func event(
        for kind: HostLumeSmokeEvent.Kind,
        workspace: HostLumeSmokeWorkspaceRecord
    ) -> HostLumeSmokeEvent {
        HostLumeSmokeEvent(
            type: kind,
            timestamp: Self.timestamp(),
            repoName: nil,
            repoPath: targetRepoURL?.path,
            workspaceName: workspace.workspaceName,
            workspacePath: workspace.workspacePath,
            providerID: workspace.providerID,
            remoteID: workspace.remoteID,
            workspaceStatus: workspace.status,
            runtimeState: nil,
            setupStep: nil,
            phaseMessage: nil,
            message: nil,
            recoveryHints: nil,
            lumeMetadata: workspace.lumeMetadata
        )
    }

    private func emit(_ event: HostLumeSmokeEvent) async {
        guard let writer else { return }
        await writer.emit(event)
    }

    private static func timestamp() -> String {
        Date().ISO8601Format()
    }
}

func hostLumeSmokeRecoveryHints(for message: String?) -> [String] {
    guard let message else { return [] }
    let normalized = message.lowercased()

    if normalized.contains("lume")
        || normalized.contains("macos vm")
        || normalized.contains("vm runtime")
        || normalized.contains("restore image")
        || normalized.contains("virtual machine not found")
    {
        return ["Open VM Runtime", "Open Lume Log"]
    }

    return []
}
